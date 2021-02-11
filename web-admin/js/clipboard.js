function RemoteClipboard(remoteChat){
    this.remoteChat = remoteChat;
    this.manage = false;
    var obj = this;  // for event handlers

    $(document).on('visibilitychange', function(e) {
        if (obj.manage) {
            $("#textareaClipboard").focus();
        }
	console.log("Visibility of page has changed!");
    });

    ui.on('RemoteChat.onManagementStart', function(){
        $("#textareaClipboard").focus();
        this.manage = true;
    }, this);

    ui.on('RemoteChat.onManagementStop', function(){
        this.manage = false;
    }, this);

    ui.on('RemoteClipboard.onRemoteCopy', function(value){
        var textareaClipboard = $("#textareaClipboard");
        textareaClipboard.focus();
        textareaClipboard.val(value);
        textareaClipboard.select();
        document.execCommand('copy');
    }, this);

    $("#textareaClipboard").bind("paste", function(e) {
        if (obj.manage) {
            var pastedData = e.originalEvent.clipboardData.getData('text');
            var encodedClipboard = pastedData.replace('%', '%25').replace(',', '%2C');
	    obj.remoteChat.sendData(`paste,${encodedClipboard}`);
        }
    });

}
