function RemoteKeyboard(remoteChat){
    this.remoteChat = remoteChat;

    $(document).on('keydown', function(e){
		var encodedKey = e.key.replace('%', '%25').replace(',', '%2C');
		this.remoteChat.sendData(`key,${encodedKey}`);
    });
}
