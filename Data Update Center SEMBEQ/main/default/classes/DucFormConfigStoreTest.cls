@IsTest
private class DucFormConfigStoreTest {

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static SObject mdt(String sobjectType, Map<String, Object> fields) {
        Map<String, Object> m = new Map<String, Object>{ 'attributes' => new Map<String, Object>{ 'type' => sobjectType } };
        m.putAll(fields);
        return (SObject) JSON.deserialize(JSON.serialize(m), Type.forName(sobjectType));
    }

    private static SObject baseForm(String devName, String label) {
        return mdt(DucFormConfigStore.FORM_TYPE, new Map<String, Object>{
            'DeveloperName' => devName, 'MasterLabel' => label, 'Is_Active__c' => true,
            'Subject_Template__c' => 'Base subject'
        });
    }

    private static SObject baseField(String devName, String formDev, Decimal displayOrder) {
        return mdt(DucFormConfigStore.FIELD_TYPE, new Map<String, Object>{
            'DeveloperName' => devName, 'MasterLabel' => devName, 'Display_Order__c' => displayOrder,
            'Label_FR__c' => 'FR ' + devName, 'Label_EN__c' => 'EN ' + devName,
            'Form__r' => new Map<String, Object>{
                'attributes' => new Map<String, Object>{ 'type' => DucFormConfigStore.FORM_TYPE },
                'DeveloperName' => formDev
            }
        });
    }

    private static SObject baseTemplate(String devName, String label) {
        return mdt(DucFormConfigStore.TEMPLATE_TYPE, new Map<String, Object>{
            'DeveloperName' => devName, 'MasterLabel' => label, 'Is_Active__c' => true
        });
    }

    private static Metadata.CustomMetadata cmd(String fullName, String label, Map<String, Object> values) {
        Metadata.CustomMetadata c = new Metadata.CustomMetadata();
        c.fullName = fullName;
        c.label = label;
        for (String field : values.keySet()) {
            Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
            v.field = field;
            v.value = values.get(field);
            c.values.add(v);
        }
        return c;
    }

    private static DUC_Form_Config__c row(String metadataType, String devName, String formDev, String label, String valuesJson, Boolean deleted) {
        return new DUC_Form_Config__c(
            Name = devName, Config_Key__c = metadataType + '.' + devName, Metadata_Type__c = metadataType,
            Developer_Name__c = devName, Form_Developer_Name__c = formDev, Label__c = label,
            Values_JSON__c = valuesJson, Is_Deleted__c = deleted
        );
    }

    private static void setBase() {
        DucFormConfigStore.baseForTest = new Map<String, List<SObject>>{
            DucFormConfigStore.FORM_TYPE => new List<SObject>{ baseForm('Form_B', 'Bravo'), baseForm('Form_A', 'Alpha') },
            DucFormConfigStore.FIELD_TYPE => new List<SObject>{
                baseField('A_First', 'Form_A', 10), baseField('A_Second', 'Form_A', 20), baseField('B_Only', 'Form_B', 5)
            },
            DucFormConfigStore.TEMPLATE_TYPE => new List<SObject>{ baseTemplate('T_Z', 'Zulu'), baseTemplate('T_A', 'Able') }
        };
    }

    private static Map<String, Object> valuesOf(String configKey) {
        DUC_Form_Config__c r = [SELECT Values_JSON__c FROM DUC_Form_Config__c WHERE Config_Key__c = :configKey];
        return (Map<String, Object>) JSON.deserializeUntyped(r.Values_JSON__c);
    }

    // ─── Read ────────────────────────────────────────────────────────────

    @IsTest
    static void forms_baseOnly_sortedByLabel() {
        setBase();
        List<Data_Update_Form__mdt> forms = DucFormConfigStore.forms();
        Assert.areEqual(2, forms.size());
        Assert.areEqual('Alpha', forms[0].MasterLabel);
        Assert.areEqual('Bravo', forms[1].MasterLabel);
        Assert.areEqual('Base subject', DucFormConfigStore.form('form_a').Subject_Template__c, 'lookup is case-insensitive');
        Assert.isNull(DucFormConfigStore.form('Missing'));
        Assert.isNull(DucFormConfigStore.form(''));
    }

    @IsTest
    static void forms_rowsOverrideAddAndHide() {
        setBase();
        insert new List<DUC_Form_Config__c>{
            row(DucFormConfigStore.FORM_TYPE, 'Form_A', 'Form_A', 'Alpha renamed', '{"Subject_Template__c":"Row subject"}', false),
            row(DucFormConfigStore.FORM_TYPE, 'Form_B', 'Form_B', null, null, true),
            row(DucFormConfigStore.FORM_TYPE, 'Form_New', 'Form_New', null, '{"Is_Active__c":true}', false)
        };
        List<Data_Update_Form__mdt> forms = DucFormConfigStore.forms();
        Assert.areEqual(2, forms.size(), 'Form_B is deleted, Form_New is added');
        Assert.isNull(forms[0].MasterLabel, 'a row without label sorts first');
        Assert.areEqual('Form_New', forms[0].DeveloperName);
        Assert.areEqual('Alpha renamed', forms[1].MasterLabel);
        Assert.areEqual('Row subject', forms[1].Subject_Template__c);
        Assert.isTrue(forms[1].Is_Active__c, 'values left out keep the base value');
        Assert.isNull(DucFormConfigStore.form('Form_B'));
    }

    @IsTest
    static void fields_mergeFormRelationshipAndOrder() {
        setBase();
        insert new List<DUC_Form_Config__c>{
            row(DucFormConfigStore.FIELD_TYPE, 'A_Second', 'Form_A', null, '{"Display_Order__c":1,"Label_FR__c":"Nouveau"}', false),
            row(DucFormConfigStore.FIELD_TYPE, 'A_New_Z', 'Form_A', null, '{"Form__c":"Form_A","Display_Order__c":null}', false),
            row(DucFormConfigStore.FIELD_TYPE, 'A_New_Y', 'Form_A', null, '{"Form__c":"Form_A"}', false),
            row(DucFormConfigStore.FIELD_TYPE, 'B_Only', 'Form_B', null, null, true),
            row(DucFormConfigStore.FIELD_TYPE, 'Orphan', null, null, '[1,2]', false)
        };
        List<Data_Update_Form_Field__mdt> a = DucFormConfigStore.fields('Form_A');
        Assert.areEqual(4, a.size());
        Assert.areEqual('A_Second', a[0].DeveloperName);
        Assert.areEqual('Nouveau', a[0].Label_FR__c);
        Assert.areEqual('EN A_Second', a[0].Label_EN__c);
        Assert.areEqual('A_First', a[1].DeveloperName);
        Assert.areEqual('A_New_Y', a[2].DeveloperName, 'blank orders last, then by name');
        Assert.areEqual('A_New_Z', a[3].DeveloperName);
        Assert.areEqual('Form_A', a[2].Form__r.DeveloperName);
        Assert.areEqual(0, DucFormConfigStore.fields('Form_B').size());
        Assert.areEqual(0, DucFormConfigStore.fields(null).size());
    }

    @IsTest
    static void appearanceTemplates_sortedByLabel() {
        setBase();
        List<Data_Update_Appearance_Template__mdt> t = DucFormConfigStore.appearanceTemplates();
        Assert.areEqual(2, t.size());
        Assert.areEqual('Able', t[0].MasterLabel);
        Assert.areEqual('Zulu', t[1].MasterLabel);
    }

    @IsTest
    static void usedDeveloperNames_includesDeletedRows() {
        setBase();
        insert row(DucFormConfigStore.FORM_TYPE, 'Gone_Form', 'Gone_Form', null, null, true);
        Set<String> names = DucFormConfigStore.usedDeveloperNames(DucFormConfigStore.FORM_TYPE);
        Assert.isTrue(names.contains('form_a'));
        Assert.isTrue(names.contains('form_b'));
        Assert.isTrue(names.contains('gone_form'));
    }

    @IsTest
    static void baseRecords_testsUseFixedFixtures() {
        // Without a seam, tests read the DucTestFormFixtures copy, whatever the org holds.
        Assert.isNotNull(DucFormConfigStore.form('SEMBEQ_Contact_Update'));
        Assert.isNotNull(DucFormConfigStore.form('SEMBEQ_Eglise_Update'));
        Assert.isFalse(DucFormConfigStore.fields('SEMBEQ_Eglise_Update').isEmpty());
        Assert.areEqual('SEMBEQ_Eglise_Update', DucFormConfigStore.fields('SEMBEQ_Eglise_Update')[0].Form__r.DeveloperName);
    }

    @IsTest
    static void baseRecords_readsRealMetadata() {
        // Every type queried from the org's Custom Metadata.
        DucFormConfigStore.useOrgMetadataForTest = true;
        Assert.isNotNull(DucFormConfigStore.forms());
        Assert.isNotNull(DucFormConfigStore.fields('Any_Form'));
        Assert.isNotNull(DucFormConfigStore.appearanceTemplates());
        Assert.isNotNull(DucFormConfigStore.usedDeveloperNames(DucFormConfigStore.FORM_TYPE), 'second read is cached');
        try {
            DucFormConfigStore.usedDeveloperNames('Unknown__mdt');
            Assert.fail('Expected StoreException');
        } catch (DucFormConfigStore.StoreException e) {
            Assert.isTrue(e.getMessage().contains('Unknown__mdt'));
        }
    }

    // ─── Write ───────────────────────────────────────────────────────────

    @IsTest
    static void save_createsThenMergesValues() {
        setBase();
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
            cmd('Data_Update_Form__mdt.Form_A', 'Alpha 2', new Map<String, Object>{ 'Subject_Template__c' => 'S1', 'Is_Active__c' => true })
        });
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
            cmd('Data_Update_Form__mdt.Form_A', null, new Map<String, Object>{ 'Is_Active__c' => false })
        });
        DUC_Form_Config__c r = [SELECT Label__c, Name, Form_Developer_Name__c, Metadata_Type__c, Is_Deleted__c
                                FROM DUC_Form_Config__c WHERE Config_Key__c = 'Data_Update_Form__mdt.Form_A'];
        Assert.areEqual('Alpha 2', r.Label__c, 'a blank label keeps the previous one');
        Assert.areEqual('Alpha 2', r.Name);
        Assert.areEqual('Form_A', r.Form_Developer_Name__c);
        Assert.areEqual(DucFormConfigStore.FORM_TYPE, r.Metadata_Type__c);
        Assert.isFalse(r.Is_Deleted__c);
        Map<String, Object> v = valuesOf('Data_Update_Form__mdt.Form_A');
        Assert.areEqual('S1', v.get('Subject_Template__c'), 'values left out are kept');
        Assert.areEqual(false, v.get('Is_Active__c'));
        Data_Update_Form__mdt f = DucFormConfigStore.form('Form_A');
        Assert.areEqual('Alpha 2', f.MasterLabel);
        Assert.isFalse(f.Is_Active__c);
    }

    @IsTest
    static void save_fieldFormNameSources() {
        setBase();
        insert row(DucFormConfigStore.FIELD_TYPE, 'A_First', 'Form_A', null, null, true);
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
            // From the values being saved.
            cmd('Data_Update_Form_Field__mdt.New_Q', 'New Q', new Map<String, Object>{ 'Form__c' => 'Form_A', 'Display_Order__c' => 30 }),
            // From the existing row (deleted base record revived).
            cmd('Data_Update_Form_Field__mdt.A_First', null, new Map<String, Object>{ 'Label_FR__c' => 'Rev' }),
            // From the base metadata record.
            cmd('Data_Update_Form_Field__mdt.B_Only', null, new Map<String, Object>{ 'Label_FR__c' => 'B2' }),
            // Unknown everywhere: no form.
            cmd('Data_Update_Form_Field__mdt.Lost', null, new Map<String, Object>{ 'Label_FR__c' => 'L' }),
            // Not a question: no form.
            cmd('Data_Update_Appearance_Template__mdt.T_New', 'New template', new Map<String, Object>{ 'Is_Active__c' => true }),
            // Same record twice in one call: merged into one row.
            cmd('Data_Update_Form_Field__mdt.New_Q', null, new Map<String, Object>{ 'Label_FR__c' => 'Q' })
        });
        Map<String, String> formByKey = new Map<String, String>();
        for (DUC_Form_Config__c r : [SELECT Developer_Name__c, Form_Developer_Name__c FROM DUC_Form_Config__c]) {
            formByKey.put(r.Developer_Name__c, r.Form_Developer_Name__c);
        }
        Assert.areEqual('Form_A', formByKey.get('New_Q'));
        Assert.areEqual('Form_A', formByKey.get('A_First'));
        Assert.areEqual('Form_B', formByKey.get('B_Only'));
        Assert.isNull(formByKey.get('Lost'));
        Assert.isNull(formByKey.get('T_New'));
        Assert.areEqual(5, formByKey.size());
        Map<String, Object> q = valuesOf('Data_Update_Form_Field__mdt.New_Q');
        Assert.areEqual('Q', q.get('Label_FR__c'));
        Assert.areEqual(30, q.get('Display_Order__c'));
        Assert.areEqual(3, DucFormConfigStore.fields('Form_A').size(), 'A_First revived + A_Second + New_Q');
        Assert.areEqual(3, DucFormConfigStore.appearanceTemplates().size());
    }

    @IsTest
    static void save_nothingToSave() {
        DucFormConfigStore.save(null);
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>());
        Assert.areEqual(0, [SELECT COUNT() FROM DUC_Form_Config__c]);
    }

    @IsTest
    static void forms_skipsDamagedRows() {
        setBase();
        DUC_Form_Config__c noName = row(DucFormConfigStore.FORM_TYPE, 'No_Name', 'No_Name', 'Nameless', '{}', false);
        noName.Developer_Name__c = null;
        insert new List<DUC_Form_Config__c>{
            row(DucFormConfigStore.FORM_TYPE, 'Bad_Json', 'Bad_Json', 'Broken', '{not json', false),
            row(DucFormConfigStore.FORM_TYPE, 'Not_Object', 'Not_Object', 'List', '[1,2]', false),
            noName
        };
        List<Data_Update_Form__mdt> forms = DucFormConfigStore.forms();
        Assert.areEqual(2, forms.size(), 'Damaged rows are ignored, the healthy forms still load');
        Assert.areEqual('Alpha', forms[0].MasterLabel);
        Set<String> names = DucFormConfigStore.usedDeveloperNames(DucFormConfigStore.FORM_TYPE);
        Assert.isTrue(names.contains('bad_json'));
        Assert.isFalse(names.contains(null));
    }

    @IsTest
    static void save_rewritesDamagedRow() {
        setBase();
        insert row(DucFormConfigStore.FORM_TYPE, 'Form_A', 'Form_A', 'Alpha', '{not json', false);
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
            cmd(DucFormConfigStore.FORM_TYPE + '.Form_A', 'Alpha', new Map<String, Object>{ 'Subject_Template__c' => 'Fixed' })
        });
        Map<String, Object> values = valuesOf(DucFormConfigStore.FORM_TYPE + '.Form_A');
        Assert.areEqual('Fixed', values.get('Subject_Template__c'));
        Assert.areEqual(1, values.size());
    }

    @IsTest
    static void save_deletedForm_throws() {
        setBase();
        insert row(DucFormConfigStore.FORM_TYPE, 'Form_A', 'Form_A', 'Alpha', '{}', true);
        try {
            DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
                cmd(DucFormConfigStore.FIELD_TYPE + '.A_New', 'A_New', new Map<String, Object>{ 'Form__c' => 'Form_A' })
            });
            Assert.fail('Expected StoreException');
        } catch (DucFormConfigStore.StoreException e) {
            Assert.isTrue(e.getMessage().contains('Form_A'));
        }
        Assert.areEqual(0, [SELECT COUNT() FROM DUC_Form_Config__c WHERE Developer_Name__c = 'A_New']);
        Assert.areEqual(1, [SELECT COUNT() FROM DUC_Form_Config__c WHERE Developer_Name__c = 'Form_A' AND Is_Deleted__c = true]);
    }

    @IsTest
    static void save_invalidName_throws() {
        setBase();
        try {
            DucFormConfigStore.save(new List<Metadata.CustomMetadata>{ cmd('NoDot', 'x', new Map<String, Object>()) });
            Assert.fail('Expected StoreException');
        } catch (DucFormConfigStore.StoreException e) {
            Assert.isTrue(e.getMessage().contains('NoDot'));
        }
    }

    @IsTest
    static void save_tooLarge_throws() {
        setBase();
        String big = 'x'.repeat(DucFormConfigStore.VALUES_MAX_LENGTH);
        try {
            DucFormConfigStore.save(new List<Metadata.CustomMetadata>{
                cmd('Data_Update_Form__mdt.Form_A', 'A', new Map<String, Object>{ 'Portal_Blocks__c' => big })
            });
            Assert.fail('Expected StoreException');
        } catch (DucFormConfigStore.StoreException e) {
            Assert.isTrue(e.getMessage().contains('too large'));
        }
        Assert.areEqual(0, [SELECT COUNT() FROM DUC_Form_Config__c]);
    }

    @IsTest
    static void deleteForm_hidesFormAndQuestions() {
        setBase();
        insert row(DucFormConfigStore.FIELD_TYPE, 'A_Extra', 'Form_A', 'Extra', '{"Form__c":"Form_A"}', false);
        Assert.areEqual(3, DucFormConfigStore.fields('Form_A').size());

        DucFormConfigStore.deleteForm('Form_A');

        Assert.isNull(DucFormConfigStore.form('Form_A'));
        Assert.areEqual(0, DucFormConfigStore.fields('Form_A').size());
        Assert.areEqual(1, DucFormConfigStore.forms().size());
        Assert.areEqual(4, [SELECT COUNT() FROM DUC_Form_Config__c WHERE Is_Deleted__c = true AND Form_Developer_Name__c = 'Form_A']);
        DUC_Form_Config__c extra = [SELECT Label__c FROM DUC_Form_Config__c WHERE Config_Key__c = 'Data_Update_Form_Field__mdt.A_Extra'];
        Assert.areEqual('Extra', extra.Label__c, 'existing rows are kept, only flagged');
        Assert.isTrue(DucFormConfigStore.usedDeveloperNames(DucFormConfigStore.FORM_TYPE).contains('form_a'));
    }
}
