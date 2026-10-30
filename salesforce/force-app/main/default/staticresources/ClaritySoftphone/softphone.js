/* Clarity Dialer softphone. Runs inside the Open CTI utility bar panel.
 * Flow: click a phone number -> Salesforce checks the call -> Twilio dials ->
 * rep talks -> rep picks a disposition -> Task saved -> back to compact. */
(function () {
  'use strict';

  var opencti = window.sforce && window.sforce.opencti;
  var app = document.getElementById('app');

  var HEIGHT = { compact: 240, dialing: 300, connected: 460, ended: 560 };
  var DISPOSITIONS = [
    'Connected - Decision Maker',
    'Connected - Gatekeeper',
    'Meeting Booked',
    'Left Voicemail',
    'No Answer',
    'Phone Tree',
    'Wrong Number'
  ];
  // Task.Conversation_Outcome__c picklist values.
  var OUTCOMES = [
    'Meeting Booked', 'Follow-Up Scheduled', 'Send Info or Proposal', 'Referred to Someone Else',
    'Interested - Bad Timing', 'Not Interested', 'Not a Fit', 'Existing Client', 'Other'
  ];

  var state = {
    view: 'idle',
    message: '',
    pending: null,   // click-to-dial payload waiting on a confirm
    prospect: null,  // CallPrep from Apex
    device: null,
    call: null,
    callSid: null,
    connectedAt: null,
    durationSeconds: 0,
    muted: false,
    showKeypad: false,
    timer: null,
    saving: false,
    firstLog: Promise.resolve() // wrap-up save waits on this so we never write two Tasks
  };

  // ---------- Salesforce plumbing ----------

  function remote(name) {
    var args = Array.prototype.slice.call(arguments, 1);
    return new Promise(function (resolve, reject) {
      var params = [window.CLARITY.actions[name]].concat(args, [
        function (result, event) {
          if (event.status) resolve(result);
          else reject(new Error(event.message || 'Salesforce request failed'));
        },
        { escape: false, timeout: 30000 }
      ]);
      Visualforce.remoting.Manager.invokeAction.apply(Visualforce.remoting.Manager, params);
    });
  }

  function cti(method, args) {
    if (opencti && typeof opencti[method] === 'function') {
      try { opencti[method](Object.assign({ callback: function () {} }, args || {})); } catch (e) { console.warn(method, e); }
    }
  }

  function setPanel(height, visible) {
    cti('setSoftphonePanelHeight', { heightPX: height });
    if (visible) cti('setSoftphonePanelVisibility', { visible: true });
  }

  function setLabel(label, icon) {
    cti('setSoftphoneItemLabel', { label: label });
    if (icon) cti('setSoftphoneItemIcon', { key: icon });
  }

  // ---------- Calling ----------

  function onClickToDial(payload) {
    setPanel(HEIGHT.compact, true);
    if (state.call) {
      flash('Finish the current call first.');
      return;
    }
    startCall({ recordId: payload.recordId, number: payload.number, name: payload.recordName }, false);
  }

  function startCall(target, confirmed) {
    state.pending = target;
    state.prospect = null;
    go('checking', 'Checking ' + (target.name || 'record') + '...');
    setLabel('Checking...', 'call');

    remote('prepareCall', target.recordId, target.number, confirmed)
      .then(function (prep) {
        state.prospect = prep;
        if (!prep.allowed) {
          go(prep.needsConfirm ? 'confirm' : 'blocked', prep.reason);
          setLabel('Phone', 'call');
          return;
        }
        state.pending = null;
        return dial(prep);
      })
      .catch(function (err) {
        go('blocked', err.message);
        setLabel('Phone', 'call');
      });
  }

  function ensureDevice(token) {
    if (state.device) {
      state.device.updateToken(token);
      return state.device;
    }
    var device = new Twilio.Device(token, {
      codecPreferences: ['opus', 'pcmu'],
      closeProtection: 'A call is in progress. Leave anyway?',
      logLevel: 'warn'
    });
    device.on('tokenWillExpire', function () {
      remote('getDeviceToken').then(function (t) { device.updateToken(t); });
    });
    device.on('error', function (err) {
      console.error('Twilio device error', err);
    });
    state.device = device;
    return device;
  }

  function dial(prep) {
    var device = ensureDevice(prep.token);
    state.callSid = null;
    state.connectedAt = null;
    state.durationSeconds = 0;
    state.muted = false;
    state.showKeypad = false;
    go('dialing', 'Calling...');
    setPanel(HEIGHT.dialing, true);
    setLabel('Dialing ' + prep.name, 'call');

    return device.connect({ params: { To: prep.to, ticket: prep.ticket } }).then(function (call) {
      state.call = call;
      call.on('ringing', function () {
        state.callSid = call.parameters.CallSid || state.callSid;
        go('dialing', 'Ringing...');
      });
      // With answerOnBridge, accept fires when the prospect picks up.
      call.on('accept', function () {
        state.callSid = call.parameters.CallSid || state.callSid;
        state.connectedAt = Date.now();
        go('connected');
        setPanel(HEIGHT.connected, true);
        startTimer();
      });
      call.on('disconnect', function () { endCall(call); });
      call.on('cancel', function () { endCall(call); });
      call.on('reject', function () { endCall(call); });
      call.on('error', function (err) {
        console.error('Twilio call error', err);
        if (err && err.code === 31208) flash('Microphone blocked. Allow the mic for Salesforce and try again.');
      });
    }).catch(function (err) {
      state.call = null;
      var micBlocked = err && (err.code === 31208 || err.name === 'NotAllowedError');
      go('blocked', micBlocked ? 'Microphone blocked. Allow the mic for Salesforce and try again.' : err.message);
      setPanel(HEIGHT.compact);
      setLabel('Phone', 'call');
    });
  }

  function hangUp() {
    if (state.call) state.call.disconnect();
  }

  function endCall(call) {
    if (state.call !== call) return; // already handled
    state.callSid = call.parameters.CallSid || state.callSid;
    state.call = null;
    stopTimer();
    state.durationSeconds = state.connectedAt ? Math.round((Date.now() - state.connectedAt) / 1000) : 0;
    go('ended');
    setPanel(HEIGHT.ended, true);
    setLabel('Wrap up', 'end_call');

    // Save a basic Task right away so nothing is lost if the rep moves on.
    if (state.callSid) {
      state.firstLog = saveLog({ disposition: state.connectedAt ? null : 'No Answer' }).catch(function (err) {
        flash('Could not save the call yet: ' + err.message);
      });
    }
  }

  function saveLog(extra) {
    var log = Object.assign({
      callSid: state.callSid,
      recordId: state.prospect.recordId,
      durationSeconds: state.durationSeconds
    }, extra);
    return remote('logCall', log);
  }

  function submitWrapUp(form) {
    if (state.saving) return;
    var disposition = form.querySelector('input[name=disposition]:checked');
    if (!disposition) {
      flash('Pick what happened on the call.');
      return;
    }
    if (!state.callSid) {
      reset('Call never reached Twilio, so nothing was logged.');
      return;
    }
    state.saving = true;
    render();
    var details = {
      disposition: disposition.value,
      outcome: form.outcome ? form.outcome.value : null,
      notes: form.notes.value.trim() || null,
      followUpDate: form.followUp.value || null,
      optOut: form.optOut.checked
    };
    state.firstLog.then(function () {
      return saveLog(details);
    }).then(function () {
      state.saving = false;
      cti('refreshView');
      reset('Saved to Salesforce.');
    }).catch(function (err) {
      state.saving = false;
      flash('Save failed: ' + err.message + '. Try again.');
    });
  }

  function reset(message) {
    state.prospect = null;
    state.callSid = null;
    state.connectedAt = null;
    go('idle', message || '');
    setPanel(HEIGHT.compact);
    setLabel('Phone', 'call');
  }

  // ---------- Timer ----------

  function startTimer() {
    stopTimer();
    state.timer = setInterval(function () {
      var el = document.getElementById('timer');
      var text = clock(Date.now() - state.connectedAt);
      if (el) el.textContent = text;
      setLabel('On call ' + text);
    }, 1000);
  }

  function stopTimer() {
    if (state.timer) clearInterval(state.timer);
    state.timer = null;
  }

  function clock(ms) {
    var s = Math.floor(ms / 1000);
    var m = Math.floor(s / 60);
    s = s % 60;
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  // ---------- Rendering ----------

  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function go(view, message) {
    state.view = view;
    state.message = message || '';
    render();
  }

  function flash(message) {
    state.message = message;
    render();
  }

  function who() {
    var p = state.prospect;
    if (!p) return '';
    var sub = [p.title, p.company].filter(Boolean).join(' · ');
    return '<div class="who"><div class="name">' + esc(p.name) + '</div>' +
      (sub ? '<div class="sub">' + esc(sub) + '</div>' : '') +
      (p.localTime ? '<div class="sub">Their time: ' + esc(p.localTime) + '</div>' : '') + '</div>';
  }

  function note() {
    return state.message ? '<p class="note">' + esc(state.message) + '</p>' : '';
  }

  var views = {
    idle: function () {
      return '<div class="idle"><div class="icon">☎</div><div class="status">Ready</div>' +
        '<p class="hint">Click any phone number on a Lead or Contact to call.</p>' + note() + '</div>';
    },
    checking: function () {
      return '<div class="idle"><div class="status">' + esc(state.message) + '</div></div>';
    },
    blocked: function () {
      return who() + '<p class="warn">' + esc(state.message) + '</p>' +
        '<button data-action="dismiss" class="secondary">OK</button>';
    },
    confirm: function () {
      return who() + '<p class="warn">' + esc(state.message) + '</p>' +
        '<div class="row"><button data-action="confirm" class="primary">Call anyway</button>' +
        '<button data-action="dismiss" class="secondary">Cancel</button></div>';
    },
    dialing: function () {
      return who() + '<div class="status pulse">' + esc(state.message) + '</div>' +
        '<button data-action="hangup" class="danger wide">Cancel call</button>';
    },
    connected: function () {
      return '<header class="bar">' + who() +
        '<div class="right"><span id="timer" class="timer">' + clock(Date.now() - state.connectedAt) + '</span>' +
        '<button data-action="minimize" class="icon-btn" title="Minimize">–</button></div></header>' +
        '<section class="coach" aria-label="Suggested response">' +
        '<div class="label">Say next</div>' +
        '<div class="suggestion muted">Live coaching turns on in the next build.</div>' +
        '<div class="cue muted">Lead with a question. Let them talk.</div></section>' +
        '<details class="transcript"><summary>Transcript</summary><p class="muted">Not recording yet.</p></details>' +
        (state.showKeypad ? keypad() : '') +
        '<div class="controls">' +
        '<button data-action="mute" class="secondary">' + (state.muted ? 'Unmute' : 'Mute') + '</button>' +
        '<button data-action="keypad" class="secondary">Keypad</button>' +
        '<button data-action="hangup" class="danger">Hang up</button></div>' + note();
    },
    ended: function () {
      var connected = !!state.connectedAt;
      var suggested = connected ? '' : 'No Answer';
      return who() + '<form id="wrap">' +
        '<div class="label">What happened? ' + (connected ? '(' + clock(state.durationSeconds * 1000) + ')' : '') + '</div>' +
        '<div class="chips">' + DISPOSITIONS.map(function (d) {
          return '<label class="chip"><input type="radio" name="disposition" value="' + esc(d) + '"' +
            (d === suggested ? ' checked' : '') + '><span>' + esc(d) + '</span></label>';
        }).join('') + '</div>' +
        (connected ? '<label class="field">Outcome<select name="outcome"><option value="">None</option>' +
          OUTCOMES.map(function (o) { return '<option>' + esc(o) + '</option>'; }).join('') + '</select></label>' : '') +
        '<label class="field">Notes<textarea name="notes" rows="3" placeholder="Short notes"></textarea></label>' +
        '<label class="field">Follow up on<input type="date" name="followUp"></label>' +
        '<label class="check"><input type="checkbox" name="optOut"> They asked us not to call again</label>' +
        '<button type="submit" class="primary wide"' + (state.saving ? ' disabled' : '') + '>' +
        (state.saving ? 'Saving...' : 'Save and finish') + '</button></form>' + note();
    }
  };

  function keypad() {
    return '<div class="keypad">' + '123456789*0#'.split('').map(function (d) {
      return '<button data-action="digit" data-digit="' + d + '">' + d + '</button>';
    }).join('') + '</div>';
  }

  function render() {
    app.className = 'view-' + state.view;
    app.innerHTML = views[state.view]();
  }

  app.addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-action]');
    if (!btn) return;
    switch (btn.dataset.action) {
      case 'hangup': hangUp(); break;
      case 'mute':
        if (state.call) { state.muted = !state.muted; state.call.mute(state.muted); render(); }
        break;
      case 'keypad': state.showKeypad = !state.showKeypad; render(); break;
      case 'digit': if (state.call) state.call.sendDigits(btn.dataset.digit); break;
      case 'minimize': cti('setSoftphonePanelVisibility', { visible: false }); break;
      case 'confirm': if (state.pending) startCall(state.pending, true); break;
      case 'dismiss': reset(); break;
    }
  });

  app.addEventListener('submit', function (e) {
    e.preventDefault();
    submitWrapUp(e.target);
  });

  // ---------- Start ----------

  render();
  if (!opencti) {
    go('blocked', 'Open CTI did not load. Open this from the Salesforce phone utility.');
  } else {
    cti('enableClickToDial');
    opencti.onClickToDial({ listener: onClickToDial });
    setLabel('Phone', 'call');
  }
})();
