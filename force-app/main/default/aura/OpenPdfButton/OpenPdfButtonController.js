({
    init : function(component, event, helper) {
        var recordId = component.get("v.recordId");

        // Agrega el parámetro isdtp=nv para evitar el iframe embebido de Lightning
        var url = '/apex/StudentRecordsPage?idContato=' + recordId + '&isdtp=nv';

        // Abre en nueva pestaña
        window.open(url, '_blank');

        // Cierra el modal
        $A.get("e.force:closeQuickAction").fire();
    }
})