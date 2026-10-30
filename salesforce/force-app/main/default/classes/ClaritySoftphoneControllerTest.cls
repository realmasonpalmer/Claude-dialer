@IsTest
private class ClaritySoftphoneControllerTest {
    // 17:00 UTC on a Wednesday: 1 PM in New York, 10 AM in Los Angeles.
    private static final Datetime AFTERNOON = Datetime.newInstanceGmt(2026, 10, 28, 17, 0, 0);
    // 03:00 UTC: 11 PM in New York.
    private static final Datetime LATE_NIGHT = Datetime.newInstanceGmt(2026, 10, 29, 3, 0, 0);

    private class BackendMock implements HttpCalloutMock {
        Integer calls = 0;
        public HttpResponse respond(HttpRequest req) {
            calls++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getEndpoint().endsWith('/api/token')) {
                res.setBody('{"token":"jwt-token","ttl":3600}');
            } else {
                res.setBody('{"to":"+15555550123","ticket":"t.sig","token":"jwt-token"}');
            }
            return res;
        }
    }

    private static Lead lead(String state, Boolean dnc) {
        Lead l = new Lead(LastName = 'Prospect', Company = 'Acme', State = state, Phone = '(555) 555-0123', DoNotCall = dnc);
        insert l;
        return l;
    }

    @IsTest
    static void approvesCallInsideCallingHours() {
        Lead l = lead('NY', false);
        BackendMock mock = new BackendMock();
        Test.setMock(HttpCalloutMock.class, mock);
        ClaritySoftphoneController.nowOverride = AFTERNOON;

        Test.startTest();
        ClaritySoftphoneController.CallPrep prep = ClaritySoftphoneController.prepareCall(l.Id, '555-555-0123', false);
        Test.stopTest();

        Assert.isTrue(prep.allowed, prep.reason);
        Assert.areEqual('t.sig', prep.ticket);
        Assert.areEqual('+15555550123', prep.to);
        Assert.areEqual('Acme', prep.company);
        Assert.areEqual(1, mock.calls);
    }

    @IsTest
    static void blocksDoNotCall() {
        Lead l = lead('NY', true);
        BackendMock mock = new BackendMock();
        Test.setMock(HttpCalloutMock.class, mock);
        ClaritySoftphoneController.nowOverride = AFTERNOON;

        ClaritySoftphoneController.CallPrep prep = ClaritySoftphoneController.prepareCall(l.Id, '5555550123', false);

        Assert.isFalse(prep.allowed);
        Assert.isTrue(prep.reason.contains('Do Not Call'));
        Assert.areEqual(0, mock.calls);
    }

    @IsTest
    static void blocksOutsideCallingHours() {
        Lead l = lead('New York', false);
        Test.setMock(HttpCalloutMock.class, new BackendMock());
        ClaritySoftphoneController.nowOverride = LATE_NIGHT;

        ClaritySoftphoneController.CallPrep prep = ClaritySoftphoneController.prepareCall(l.Id, '5555550123', false);

        Assert.isFalse(prep.allowed);
        Assert.isTrue(prep.reason.contains('Outside calling hours'), prep.reason);
    }

    @IsTest
    static void blocksNumberNotOnRecord() {
        Lead l = lead('NY', false);
        Test.setMock(HttpCalloutMock.class, new BackendMock());
        ClaritySoftphoneController.nowOverride = AFTERNOON;

        ClaritySoftphoneController.CallPrep prep = ClaritySoftphoneController.prepareCall(l.Id, '5555559999', false);

        Assert.isFalse(prep.allowed);
        Assert.areEqual('That number is not on this record.', prep.reason);
    }

    @IsTest
    static void unknownTimeZoneFollowsSetting() {
        Lead l = lead(null, false);
        Test.setMock(HttpCalloutMock.class, new BackendMock());
        Test.startTest(); // DML above must not block the callout below

        ClaritySoftphoneController.CallPrep first = ClaritySoftphoneController.prepareCall(l.Id, '5555550123', false);
        Assert.isFalse(first.allowed);

        Clarity_Dialer_Setting__mdt s = Clarity_Dialer_Setting__mdt.getInstance('Default');
        if (s != null && s.Allow_Unknown_Time_Zone__c == true) {
            Assert.isTrue(first.needsConfirm);
            ClaritySoftphoneController.CallPrep second = ClaritySoftphoneController.prepareCall(l.Id, '5555550123', true);
            Assert.isTrue(second.allowed, second.reason);
        }
        Test.stopTest();
    }

    @IsTest
    static void contactInSplitStateUsesBothZones() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact c = new Contact(LastName = 'Buyer', AccountId = a.Id, MailingState = 'TX', MobilePhone = '+1 555 555 0123');
        insert c;
        Test.setMock(HttpCalloutMock.class, new BackendMock());
        ClaritySoftphoneController.nowOverride = AFTERNOON;

        Test.startTest();
        ClaritySoftphoneController.CallPrep prep = ClaritySoftphoneController.prepareCall(c.Id, '5555550123', false);
        Test.stopTest();

        Assert.isTrue(prep.allowed, prep.reason);
        Assert.areEqual('Contact', prep.objectType);
        Assert.areEqual(2, ClaritySoftphoneController.timeZonesFor('Texas').size());
    }

    @IsTest
    static void rejectsOtherObjects() {
        Account a = new Account(Name = 'Acme');
        insert a;
        try {
            ClaritySoftphoneController.prepareCall(a.Id, '5555550123', false);
            Assert.fail('Expected an error');
        } catch (ClaritySoftphoneController.DialerException e) {
            Assert.isTrue(e.getMessage().contains('Lead or Contact'));
        }
    }

    @IsTest
    static void logCallIsIdempotentAndHandlesOptOutAndFollowUp() {
        Lead l = lead('NY', false);

        ClaritySoftphoneController.CallLog log = new ClaritySoftphoneController.CallLog();
        log.callSid = 'CA123';
        log.recordId = l.Id;
        log.durationSeconds = 42;
        String firstId = ClaritySoftphoneController.logCall(log);

        log.disposition = 'Connected - Decision Maker';
        log.notes = 'Asked to call back next week.';
        log.followUpDate = String.valueOf(Date.today().addDays(7));
        log.optOut = true;
        String secondId = ClaritySoftphoneController.logCall(log);
        ClaritySoftphoneController.logCall(log);

        Assert.areEqual(firstId, secondId);
        Task call = [SELECT CallDisposition, CallDurationInSeconds, CallType, Description FROM Task WHERE Id = :firstId];
        Assert.areEqual('Connected - Decision Maker', call.CallDisposition);
        Assert.areEqual(42, call.CallDurationInSeconds);
        Assert.areEqual('Outbound', call.CallType);
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject LIKE 'Follow up:%']);
        Assert.isTrue([SELECT DoNotCall FROM Lead WHERE Id = :l.Id].DoNotCall);
    }

    @IsTest
    static void getsDeviceToken() {
        Test.setMock(HttpCalloutMock.class, new BackendMock());
        Assert.areEqual('jwt-token', ClaritySoftphoneController.getDeviceToken());
    }
}
