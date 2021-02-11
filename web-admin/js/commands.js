function Commands(remoteChat, remoteVideo){
    this.removeVideo = remoteVideo;
    this.remoteChat = remoteChat;
    this.commands = new Map();
    var obj = this;

    this.commands.set('streamingVideoResolution', function(w, h){
        obj.removeVideo.setResolution(w, h);
    });
    this.commands.set('pong', function(timestamp){
        ui.emit('SessionMonitoring.onPong', timestamp);
    });
    this.commands.set('copy', function(value){
        ui.emit('RemoteClipboard.onRemoteCopy', value.replace('%2C', ',').replace('%25', '%'));
    });


    this.process = function(message){
        let ret = undefined;
        let parts = this.splitCSV(message);
        let command = parts[0];
        let commandFunc = this.commands.get(command);
        if(commandFunc){
            console.info(`Commands: get command "${command}" with args ${parts.slice(1)}`);
            ret = commandFunc.apply(null, parts.slice(1));
        } else {
            console.debug(`Commands: skip regular message "${message}"`)
        }
        return ret
    }

    this.csvSeparator = ',';
    this.quoteChars = "\"'";
    this.splitCSV = function(string){
        let ret = [];

        let block = '';
        let isBlockEnded = false;
        let isQuotedBlock = false;
        let currentQuoteChar = '';

        for (let char of string){
            let isCharQuoted = this.quoteChars.indexOf(char) > -1;
            let isSeparator = char === this.csvSeparator;

            if (isSeparator){
                if (isQuotedBlock && !isBlockEnded){
                    block += char;
                } else {
                    ret.push(block);
                    block = '';
                    isBlockEnded = false;
                    isQuotedBlock = false;
                    currentQuoteChar = '';
                }
            } else if (isCharQuoted){
                if (!isQuotedBlock){
                    if(block.trim() === ''){
                        block = '';
                    }
                    isQuotedBlock = true;
                    currentQuoteChar = char;
                } else {
                    if (char === currentQuoteChar){
                        isBlockEnded = true;
                    } else {
                        block += char;
                    }
                }
            } else if (!isBlockEnded) {
                block += char;
            }

        }
        ret.push(block);
        return ret;
    }
}
