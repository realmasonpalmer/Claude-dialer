/**
 * Server side of the Clarity Dialer softphone (Visualforce page ClaritySoftphone).
 *
 * Every dial goes through prepareCall: it checks Do Not Call, the suppression
 * list and calling hours, then asks the backend for a one-time Twilio ticket
 * for that exact number. The browser cannot dial a number Salesforce did not approve.
 */
public with sharing class ClaritySoftphoneController {
    @TestVisible
    private static final String BACKEND = 'callout:ClarityDialer';
    @TestVisible
    private static Datetime nowOverride;

    public class DialerException extends Exception {
    }

    public class CallPrep {
        public Boolean allowed = false;
        public Boolean needsConfirm = false;
        public String reason;
        public String recordId;
        public String objectType;
        public String name;
        public String company;
        public String title;
        public String localTime;
        public String to;
        public String ticket;
        public String token;
    }

    public class CallLog {
        public String callSid;
        public String recordId;
        public Integer durationSeconds;
        public String disposition;
        public String outcome;
        public String notes;
        public String followUpDate; // yyyy-MM-dd
        public Boolean optOut;
    }

    // ---------- Remote actions ----------

    @RemoteAction
    public static String getDeviceToken() {
        Map<String, Object> res = post('/api/token', new Map<String, Object>{ 'userId' => UserInfo.getUserId() });
        return (String) res.get('token');
    }

    @RemoteAction
    public static CallPrep prepareCall(String recordId, String phone, Boolean confirmedUnknownTimeZone) {
        CallPrep prep = new CallPrep();
        Prospect p = loadProspect(recordId);
        prep.recordId = p.id;
        prep.objectType = p.objectType;
        prep.name = p.name;
        prep.company = p.company;
        prep.title = p.title;

        Clarity_Dialer_Setting__mdt settings = settings();

        if (p.doNotCall) {
            prep.reason = 'This record is marked Do Not Call.';
            return prep;
        }
        if (p.status != null && blockedStatuses(settings).contains(p.status.toLowerCase())) {
            prep.reason = 'Lead status "' + p.status + '" is on the do not call list.';
            return prep;
        }
        if (!p.hasPhone(phone)) {
            prep.reason = 'That number is not on this record.';
            return prep;
        }

        List<String> zones = timeZonesFor(p.state);
        if (zones.isEmpty()) {
            if (settings.Allow_Unknown_Time_Zone__c != true) {
                prep.reason = 'No state on this record, so calling hours cannot be checked.';
                return prep;
            }
            if (confirmedUnknownTimeZone != true) {
                prep.needsConfirm = true;
                prep.reason = 'No state on this record. Make sure it is between ' +
                    hourLabel(startHour(settings)) + ' and ' + hourLabel(endHour(settings)) + ' for them.';
                return prep;
            }
        } else {
            Datetime now = nowOverride != null ? nowOverride : Datetime.now();
            // States that span two zones must be inside the window in both.
            for (String tz : zones) {
                Integer hour = Integer.valueOf(now.format('H', tz));
                if (hour < startHour(settings) || hour >= endHour(settings)) {
                    prep.reason = 'Outside calling hours. It is ' + now.format('h:mm a', tz) + ' for them.';
                    return prep;
                }
            }
            prep.localTime = now.format('h:mm a z', zones[0]);
        }

        Map<String, Object> auth = post(
            '/api/calls/authorize',
            new Map<String, Object>{ 'userId' => UserInfo.getUserId(), 'recordId' => p.id, 'to' => phone }
        );
        prep.to = (String) auth.get('to');
        prep.ticket = (String) auth.get('ticket');
        prep.token = (String) auth.get('token');
        prep.allowed = true;
        return prep;
    }

    /**
     * Creates or updates the call Task. Safe to call more than once per call:
     * the Twilio CallSid in CallObject keeps it to one Task.
     */
    @RemoteAction
    public static String logCall(CallLog log) {
        if (log == null || String.isBlank(log.callSid) || String.isBlank(log.recordId)) {
            throw new DialerException('Missing call details.');
        }
        Prospect p = loadProspect(log.recordId);

        List<Task> existing = [
            SELECT Id
            FROM Task
            WHERE CallObject = :log.callSid AND OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            LIMIT 1
        ];
        Task t = existing.isEmpty() ? new Task() : existing[0];
        t.WhoId = p.id;
        t.Subject = 'Call: ' + (String.isBlank(log.disposition) ? 'Outbound' : log.disposition);
        t.Status = 'Completed';
        if (t.Id == null) {
            t.TaskSubtype = 'Call'; // create-only field
        }
        t.ActivityDate = Date.today();
        t.CallType = 'Outbound';
        t.CallObject = log.callSid;
        if (log.durationSeconds != null) {
            t.CallDurationInSeconds = log.durationSeconds;
        }
        if (String.isNotBlank(log.disposition)) {
            t.CallDisposition = log.disposition;
        }
        if (String.isNotBlank(log.notes)) {
            t.Description = log.notes;
        }
        putIfField(t, 'Conversation_Outcome__c', log.outcome);
        putIfField(t, 'Call_Summary__c', log.notes == null ? null : log.notes.left(255));

        if (t.Id == null) {
            Database.insert(t, AccessLevel.USER_MODE);
        } else {
            Database.update(t, AccessLevel.USER_MODE);
        }

        if (log.optOut == true && !p.doNotCall) {
            SObject rec = p.id.getSobjectType().newSObject(p.id);
            rec.put('DoNotCall', true);
            Database.update(rec, AccessLevel.USER_MODE);
        }

        if (String.isNotBlank(log.followUpDate)) {
            createFollowUp(p, Date.valueOf(log.followUpDate));
        }
        return t.Id;
    }

    // ---------- Helpers ----------

    private static void createFollowUp(Prospect p, Date due) {
        String subject = 'Follow up: ' + p.name;
        Integer open = [
            SELECT COUNT()
            FROM Task
            WHERE WhoId = :p.id AND Subject = :subject AND ActivityDate = :due AND IsClosed = FALSE
            WITH USER_MODE
        ];
        if (open > 0) {
            return;
        }
        Task f = new Task(
            WhoId = p.id,
            Subject = subject,
            ActivityDate = due,
            Status = 'Not Started',
            Priority = 'Normal',
            OwnerId = UserInfo.getUserId()
        );
        Database.insert(f, AccessLevel.USER_MODE);
    }

    private static void putIfField(SObject rec, String field, String value) {
        if (String.isBlank(value)) {
            return;
        }
        if (rec.getSObjectType().getDescribe().fields.getMap().containsKey(field.toLowerCase())) {
            rec.put(field, value);
        }
    }

    private class Prospect {
        Id id;
        String objectType;
        String name;
        String company;
        String title;
        String state;
        String status;
        Boolean doNotCall = false;
        List<String> phones = new List<String>();

        Boolean hasPhone(String phone) {
            String target = digits(phone);
            for (String candidate : phones) {
                if (String.isNotBlank(candidate) && digits(candidate) == target) {
                    return true;
                }
            }
            return false;
        }
    }

    private static Prospect loadProspect(String recordId) {
        Id rid;
        try {
            rid = Id.valueOf(recordId);
        } catch (Exception e) {
            throw new DialerException('Open a Lead or Contact to call.');
        }
        Prospect p = new Prospect();
        p.id = rid;
        if (rid.getSobjectType() == Lead.SObjectType) {
            Lead l = [
                SELECT Id, Name, Company, Title, State, Status, DoNotCall, Phone, MobilePhone
                FROM Lead
                WHERE Id = :rid
                WITH USER_MODE
            ];
            p.objectType = 'Lead';
            p.name = l.Name;
            p.company = l.Company;
            p.title = l.Title;
            p.state = l.State;
            p.status = l.Status;
            p.doNotCall = l.DoNotCall == true;
            p.phones.addAll(new List<String>{ l.Phone, l.MobilePhone });
        } else if (rid.getSobjectType() == Contact.SObjectType) {
            Contact c = [
                SELECT Id, Name, Account.Name, Title, MailingState, DoNotCall,
                    Phone, MobilePhone, HomePhone, OtherPhone, AssistantPhone
                FROM Contact
                WHERE Id = :rid
                WITH USER_MODE
            ];
            p.objectType = 'Contact';
            p.name = c.Name;
            p.company = c.Account?.Name;
            p.title = c.Title;
            p.state = c.MailingState;
            p.doNotCall = c.DoNotCall == true;
            p.phones.addAll(new List<String>{ c.Phone, c.MobilePhone, c.HomePhone, c.OtherPhone, c.AssistantPhone });
        } else {
            throw new DialerException('Open a Lead or Contact to call.');
        }
        return p;
    }

    private static String digits(String phone) {
        String d = phone == null ? '' : phone.replaceAll('[^0-9]', '');
        return d.length() == 11 && d.startsWith('1') ? d.substring(1) : d;
    }

    private static Map<String, Object> post(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BACKEND + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(10000);
        req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new DialerException('Dialer server error ' + res.getStatusCode() + ': ' + res.getBody().left(200));
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    // ---------- Calling hours ----------

    private static Clarity_Dialer_Setting__mdt settings() {
        Clarity_Dialer_Setting__mdt s = Clarity_Dialer_Setting__mdt.getInstance('Default');
        return s != null ? s : new Clarity_Dialer_Setting__mdt(Allow_Unknown_Time_Zone__c = false);
    }

    private static Integer startHour(Clarity_Dialer_Setting__mdt s) {
        return s.Call_Window_Start_Hour__c == null ? 8 : s.Call_Window_Start_Hour__c.intValue();
    }

    private static Integer endHour(Clarity_Dialer_Setting__mdt s) {
        return s.Call_Window_End_Hour__c == null ? 20 : s.Call_Window_End_Hour__c.intValue();
    }

    private static String hourLabel(Integer h) {
        return (Math.mod(h + 11, 12) + 1) + (h < 12 ? ' AM' : ' PM');
    }

    private static Set<String> blockedStatuses(Clarity_Dialer_Setting__mdt s) {
        Set<String> out = new Set<String>();
        if (String.isNotBlank(s.Blocked_Lead_Statuses__c)) {
            for (String v : s.Blocked_Lead_Statuses__c.split(',')) {
                out.add(v.trim().toLowerCase());
            }
        }
        return out;
    }

    private static final String ET = 'America/New_York', CT = 'America/Chicago', MT = 'America/Denver';
    private static final String PT = 'America/Los_Angeles', AZ = 'America/Phoenix';

    // US states and Canadian provinces. States split across zones list both.
    private static final Map<String, List<String>> ZONES = new Map<String, List<String>>{
        'AL' => new List<String>{ CT }, 'AK' => new List<String>{ 'America/Anchorage', 'America/Adak' },
        'AZ' => new List<String>{ AZ }, 'AR' => new List<String>{ CT }, 'CA' => new List<String>{ PT },
        'CO' => new List<String>{ MT }, 'CT' => new List<String>{ ET }, 'DE' => new List<String>{ ET },
        'DC' => new List<String>{ ET }, 'FL' => new List<String>{ ET, CT }, 'GA' => new List<String>{ ET },
        'HI' => new List<String>{ 'Pacific/Honolulu' }, 'ID' => new List<String>{ MT, PT },
        'IL' => new List<String>{ CT }, 'IN' => new List<String>{ ET, CT }, 'IA' => new List<String>{ CT },
        'KS' => new List<String>{ CT, MT }, 'KY' => new List<String>{ ET, CT }, 'LA' => new List<String>{ CT },
        'ME' => new List<String>{ ET }, 'MD' => new List<String>{ ET }, 'MA' => new List<String>{ ET },
        'MI' => new List<String>{ ET, CT }, 'MN' => new List<String>{ CT }, 'MS' => new List<String>{ CT },
        'MO' => new List<String>{ CT }, 'MT' => new List<String>{ MT }, 'NE' => new List<String>{ CT, MT },
        'NV' => new List<String>{ PT }, 'NH' => new List<String>{ ET }, 'NJ' => new List<String>{ ET },
        'NM' => new List<String>{ MT }, 'NY' => new List<String>{ ET }, 'NC' => new List<String>{ ET },
        'ND' => new List<String>{ CT, MT }, 'OH' => new List<String>{ ET }, 'OK' => new List<String>{ CT },
        'OR' => new List<String>{ PT, MT }, 'PA' => new List<String>{ ET }, 'RI' => new List<String>{ ET },
        'SC' => new List<String>{ ET }, 'SD' => new List<String>{ CT, MT }, 'TN' => new List<String>{ ET, CT },
        'TX' => new List<String>{ CT, MT }, 'UT' => new List<String>{ MT }, 'VT' => new List<String>{ ET },
        'VA' => new List<String>{ ET }, 'WA' => new List<String>{ PT }, 'WV' => new List<String>{ ET },
        'WI' => new List<String>{ CT }, 'WY' => new List<String>{ MT }, 'PR' => new List<String>{ 'America/Puerto_Rico' },
        'AB' => new List<String>{ 'America/Edmonton' }, 'BC' => new List<String>{ 'America/Vancouver' },
        'MB' => new List<String>{ 'America/Winnipeg' }, 'NB' => new List<String>{ 'America/Moncton' },
        'NL' => new List<String>{ 'America/St_Johns' }, 'NS' => new List<String>{ 'America/Halifax' },
        'ON' => new List<String>{ 'America/Toronto', 'America/Winnipeg' }, 'PE' => new List<String>{ 'America/Halifax' },
        'QC' => new List<String>{ 'America/Toronto' }, 'SK' => new List<String>{ 'America/Regina' }
    };

    private static final String STATE_NAMES =
        'alabama:AL,alaska:AK,arizona:AZ,arkansas:AR,california:CA,colorado:CO,connecticut:CT,delaware:DE,' +
        'district of columbia:DC,florida:FL,georgia:GA,hawaii:HI,idaho:ID,illinois:IL,indiana:IN,iowa:IA,' +
        'kansas:KS,kentucky:KY,louisiana:LA,maine:ME,maryland:MD,massachusetts:MA,michigan:MI,minnesota:MN,' +
        'mississippi:MS,missouri:MO,montana:MT,nebraska:NE,nevada:NV,new hampshire:NH,new jersey:NJ,' +
        'new mexico:NM,new york:NY,north carolina:NC,north dakota:ND,ohio:OH,oklahoma:OK,oregon:OR,' +
        'pennsylvania:PA,rhode island:RI,south carolina:SC,south dakota:SD,tennessee:TN,texas:TX,utah:UT,' +
        'vermont:VT,virginia:VA,washington:WA,west virginia:WV,wisconsin:WI,wyoming:WY,puerto rico:PR,' +
        'alberta:AB,british columbia:BC,manitoba:MB,new brunswick:NB,newfoundland and labrador:NL,' +
        'nova scotia:NS,ontario:ON,prince edward island:PE,quebec:QC,saskatchewan:SK';

    @TestVisible
    private static List<String> timeZonesFor(String state) {
        if (String.isBlank(state)) {
            return new List<String>();
        }
        String key = state.trim().toUpperCase();
        if (!ZONES.containsKey(key)) {
            for (String pair : STATE_NAMES.split(',')) {
                if (pair.substringBefore(':') == state.trim().toLowerCase()) {
                    key = pair.substringAfter(':');
                    break;
                }
            }
        }
        return ZONES.containsKey(key) ? ZONES.get(key) : new List<String>();
    }
}
