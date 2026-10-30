/* Clarity Call Coach: mic -> server -> live transcript + Claude's next line. */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var HOLD_MS = 2500; // a new line never replaces one the rep has had less than this long to read

  // Runs on the audio thread: turns mic audio into 16 kHz 16-bit PCM in 40 ms chunks.
  var WORKLET = [
    'class Pcm16 extends AudioWorkletProcessor {',
    '  constructor() { super(); this.ratio = sampleRate / 16000; this.pos = 0; this.out = new Int16Array(640); this.n = 0; }',
    '  process(inputs) {',
    '    var ch = inputs[0] && inputs[0][0]; if (!ch) return true;',
    '    while (this.pos < ch.length) {',
    '      var i = Math.floor(this.pos), f = this.pos - i, a = ch[i], b = i + 1 < ch.length ? ch[i + 1] : a;',
    '      var s = Math.max(-1, Math.min(1, a + (b - a) * f));',
    '      this.out[this.n++] = s < 0 ? s * 0x8000 : s * 0x7fff;',
    '      if (this.n === this.out.length) { this.port.postMessage(this.out.buffer, [this.out.buffer]); this.out = new Int16Array(640); this.n = 0; }',
    '      this.pos += this.ratio;',
    '    }',
    '    this.pos -= ch.length;',
    '    return true;',
    '  }',
    '}',
    'registerProcessor("pcm16", Pcm16);'
  ].join('\n');

  var ws = null, audio = null, stream = null;
  var shown = { id: 0, at: 0 }, pending = null, holdTimer = null;
  var repSpeaker = null;

  function store(key, value) {
    try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch (e) { return null; }
  }

  async function listMics() {
    try {
      var devices = await navigator.mediaDevices.enumerateDevices();
      var mics = devices.filter(function (d) { return d.kind === 'audioinput'; });
      var saved = store('coach.mic');
      $('mic').innerHTML = mics.map(function (d, i) {
        var label = d.label || ('Microphone ' + (i + 1));
        return '<option value="' + d.deviceId + '"' + (d.deviceId === saved ? ' selected' : '') + '>' + escapeHtml(label) + '</option>';
      }).join('');
    } catch (e) { /* labels appear after mic permission */ }
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  async function start() {
    var code = $('code').value.trim();
    if (!code) return setupMsg('Enter the access code.');
    store('coach.code', code);
    store('coach.mic', $('mic').value);
    setupMsg('');

    try {
      // Echo cancellation off: it would erase the prospect's voice coming out of the speaker.
      stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          deviceId: $('mic').value ? { exact: $('mic').value } : undefined,
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: true,
          channelCount: 1
        }
      });
    } catch (e) {
      return setupMsg('Could not use the microphone. Allow mic access and try again.');
    }
    listMics();

    audio = new AudioContext();
    var url = URL.createObjectURL(new Blob([WORKLET], { type: 'application/javascript' }));
    await audio.audioWorklet.addModule(url);
    var node = new AudioWorkletNode(audio, 'pcm16');
    audio.createMediaStreamSource(stream).connect(node);

    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host + '/coach/ws?code=' + encodeURIComponent(code));
    ws.binaryType = 'arraybuffer';
    ws.onopen = function () {
      sendNotes();
      node.port.onmessage = function (e) { if (ws && ws.readyState === 1) ws.send(e.data); };
    };
    ws.onmessage = function (e) { handle(JSON.parse(e.data)); };
    ws.onclose = function (e) {
      if (!ws) return;
      setStatus(e.code === 1006 && !shown.id ? 'Could not connect. Check the access code.' : 'Disconnected. Press Stop, then Start.');
    };

    $('setup').hidden = true;
    $('live').hidden = false;
    setStatus('Connecting...');
  }

  function stop() {
    var socket = ws;
    ws = null;
    if (socket) socket.close();
    if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
    if (audio) audio.close();
    stream = audio = null;
    clearTimeout(holdTimer);
    pending = null;
    shown = { id: 0, at: 0 };
    repSpeaker = null;
    clearCall();
    $('transcript').innerHTML = '';
    $('live').hidden = true;
    $('setup').hidden = false;
  }

  function sendNotes() {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'notes', notes: $('notes').value }));
  }

  function handle(msg) {
    if (msg.type === 'status') setStatus(msg.message);
    else if (msg.type === 'transcript') renderTranscript(msg);
    else if (msg.type === 'latency') $('latency').textContent = (msg.speechEndToFirstWordMs / 1000).toFixed(1) + 's';
    else if (msg.type === 'suggestion') offer(msg);
    else if (msg.type === 'reset') clearCall();
  }

  function clearCall() {
    clearTimeout(holdTimer);
    pending = null;
    shown = { id: 0, at: 0 };
    $('say').textContent = 'Getting your opener ready...';
    $('cue').textContent = '';
    $('kind').textContent = 'Say next';
    $('stage').hidden = true;
    $('latency').textContent = '';
    $('interim').textContent = '';
  }

  function nextCall() {
    if (!ws || ws.readyState !== 1) return;
    var who = $('nextNotes').value.trim();
    $('notes').value = who;
    $('nextNotes').value = '';
    ws.send(JSON.stringify({ type: 'nextCall', notes: who }));
  }

  // Suggestions: stream the current one in place, but hold a brand new one
  // until the rep has had time to read what is on screen.
  function offer(s) {
    if (s.skip || !s.say) return; // keep the last good line on screen
    if (s.id === shown.id) return paint(s);
    if (s.id < shown.id) return;
    if (s.kind === 'opener') return show(s); // nothing to read yet, show it now
    var waited = Date.now() - shown.at;
    if (!shown.id || waited >= HOLD_MS) return show(s);
    pending = s;
    clearTimeout(holdTimer);
    holdTimer = setTimeout(function () { if (pending) show(pending); }, HOLD_MS - waited);
  }

  function show(s) {
    pending = null;
    shown = { id: s.id, at: Date.now() };
    paint(s);
    var card = $('card');
    card.classList.add('fresh');
    setTimeout(function () { card.classList.remove('fresh'); }, 600);
  }

  function paint(s) {
    $('say').textContent = s.say;
    $('cue').textContent = s.cue || '';
    $('kind').textContent = s.kind === 'opener' ? 'When they pick up' : 'Say next';
    if (s.stage) { $('stage').textContent = s.stage; $('stage').hidden = false; }
  }

  function renderTranscript(msg) {
    repSpeaker = msg.rep;
    var list = $('transcript');
    var atBottom = list.scrollTop + list.clientHeight >= list.scrollHeight - 20;
    list.innerHTML = msg.turns.map(function (t) {
      var who = repSpeaker === null ? 'Speaker ' + t.speaker : (t.speaker === repSpeaker ? 'You' : 'Prospect');
      return '<li data-speaker="' + t.speaker + '" class="' + (t.speaker === repSpeaker ? 'rep' : '') + '">' +
        '<b>' + who + '</b>' + escapeHtml(t.text) + '</li>';
    }).join('');
    $('interim').textContent = msg.interim || '';
    if (atBottom) list.scrollTop = list.scrollHeight;
  }

  function setStatus(text) { $('status').textContent = text; }
  function setupMsg(text) { $('setupMsg').textContent = text; $('setupMsg').hidden = !text; }

  $('start').addEventListener('click', start);
  $('stop').addEventListener('click', stop);
  $('nextCall').addEventListener('click', nextCall);
  $('nextNotes').addEventListener('keydown', function (e) { if (e.key === 'Enter') nextCall(); });
  $('notes').addEventListener('change', sendNotes);
  $('transcript').addEventListener('click', function (e) {
    var li = e.target.closest('li[data-speaker]');
    if (li && ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'setRep', speaker: Number(li.dataset.speaker) }));
  });

  $('code').value = store('coach.code') || '';
  listMics();
})();
