function SessionMonitoring(remoteChat){
    this.remoteChat = remoteChat;

    this.pingInterval = null;
    this.pingIntervalDelayMillis = 2000;

    this.criticalDelay = 30000;

    this.lastPingSentFrom = 0;
    this.lastPongReceivedFrom = 0;

    this.start = function(){
        this.stop();
        (function (self, delay) {
            self.pingInterval = window.setInterval(function () {
                var currentTimestamp = new Date().getTime();
                if (self.lastPingSentFrom){
                    if (self.lastPongReceivedFrom + self.pingIntervalDelayMillis*2 < currentTimestamp) {
                        ui.showWarning(`Network problems`, 'Device management', null, null, self.pingIntervalDelayMillis);
                    }
                    if (self.lastPongReceivedFrom + self.criticalDelay < currentTimestamp){
                        ui.emit('Session.Disconnect');
                    }
                }
                self.sendPing(currentTimestamp);
            }, delay);
        })(this, this.pingIntervalDelayMillis);
    }

    ui.on('RemoteChat.onManagementStart', function(){
        this.start();
    }, this);

    ui.on('RemoteChat.onManagementStop', function(){
        this.stop();
    }, this);

    ui.on('SessionMonitoring.onPong', function(timestamp){
        this.getPong(timestamp);
    }, this);

    this.stop = function(){
        window.clearInterval(this.pingInterval);
        this.pingInterval = null;
        this.lastPingSentFrom = 0;
        this.lastPongReceivedFrom = 0;

    }

    this.sendPing = function(pingTimestamp){
        this.remoteChat.sendData(`ping,${pingTimestamp}`);
        this.lastPingSentFrom = pingTimestamp;
    }

    this.getPong = function(pongTimestamp){
        pongTimestamp = parseInt(pongTimestamp);
        if (pongTimestamp > this.lastPongReceivedFrom){
            this.lastPongReceivedFrom = pongTimestamp;
        }
    }
}
