function RemoteVideo(remoteVideoElem, videoLoader, videoStats) {
    this.streaming = null;
    this.remoteVideoElem = remoteVideoElem;
    this.videoLoader = videoLoader;
    this.videoStats = videoStats;
    this.stream = null;
    this.mountpointId = null;

    this.videoResolution = null;
    this.isVideoAlreadyPlayed = false;

    this._frameProbeTimer = null;
    this._frameProbeCanvas = null;
    this._waitingForPaint = false;
    this._rvfcHandle = null;

    var obj = this;  // for event handlers

    this.getStreamVideotracks = function(){
        return this.stream ? this.stream.getVideoTracks() : [];
    }

    this._stopFrameProbe = function () {
        if (this._frameProbeTimer) {
            clearInterval(this._frameProbeTimer);
            this._frameProbeTimer = null;
        }
        var video = this.remoteVideoElem.get(0);
        if (this._rvfcHandle != null && video && typeof video.cancelVideoFrameCallback === 'function') {
            try {
                video.cancelVideoFrameCallback(this._rvfcHandle);
            } catch (e) { /* ignore */ }
            this._rvfcHandle = null;
        }
        this._waitingForPaint = false;
    }

    /**
     * True while the decoded frame is still blank (no stream yet, or solid white/black).
     * Used so the placeholder stays up during the late-IDR / white-screen gap on ColorOS.
     */
    this._isBlankVideoFrame = function (video) {
        if (!video || !video.videoWidth || !video.videoHeight) {
            return true;
        }
        if (!this._frameProbeCanvas) {
            this._frameProbeCanvas = document.createElement('canvas');
        }
        var canvas = this._frameProbeCanvas;
        var w = 48;
        var h = 48;
        canvas.width = w;
        canvas.height = h;
        var ctx = canvas.getContext('2d', { willReadFrequently: true });
        if (!ctx) {
            return false;
        }
        try {
            ctx.drawImage(video, 0, 0, w, h);
            var data = ctx.getImageData(0, 0, w, h).data;
        } catch (e) {
            // SecurityError / not ready yet — treat as blank
            return true;
        }
        var sum = 0;
        var sumSq = 0;
        var n = w * h;
        for (var i = 0; i < data.length; i += 4) {
            var y = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
            sum += y;
            sumSq += y * y;
        }
        var mean = sum / n;
        var variance = (sumSq / n) - (mean * mean);
        // Solid white (~255) or black (~0) with almost no detail.
        return variance < 120;
    }

    this._revealVideoIfReady = function () {
        if (!this._waitingForPaint) {
            return;
        }
        var video = this.remoteVideoElem.get(0);
        if (!this._isBlankVideoFrame(video)) {
            console.info('video: first non-blank frame detected — hiding placeholder');
            this._stopFrameProbe();
            this.videoLoader.hide();
            this.isVideoAlreadyPlayed = true;
            if (video.videoWidth && video.videoHeight) {
                this.setResolution(video.videoWidth, video.videoHeight);
            }
        }
    }

    this._startWaitingForPaint = function () {
        this._stopFrameProbe();
        this._waitingForPaint = true;
        this.videoLoader.show('Waiting for screen…');
        var waitStartedAt = Date.now();
        var maxWaitMs = 45000;

        var video = this.remoteVideoElem.get(0);
        if (video && typeof video.requestVideoFrameCallback === 'function') {
            var onFrame = function () {
                obj._revealVideoIfReady();
                if (obj._waitingForPaint) {
                    obj._rvfcHandle = video.requestVideoFrameCallback(onFrame);
                }
            };
            this._rvfcHandle = video.requestVideoFrameCallback(onFrame);
        }

        this._frameProbeTimer = setInterval(function () {
            if (Date.now() - waitStartedAt > maxWaitMs && obj._waitingForPaint) {
                console.warn('video: placeholder timeout — showing stream anyway');
                obj._stopFrameProbe();
                obj.videoLoader.hide();
                obj.isVideoAlreadyPlayed = true;
                return;
            }
            obj._revealVideoIfReady();
        }, 400);
    }

    this.isWaitingForPaint = function () {
        return this._waitingForPaint;
    }

    this.noRemoteVideo = function () {
        this._stopFrameProbe();
        if (!this.isVideoAlreadyPlayed || window.debugUtils.isDebugEnabled()) {
            this.videoLoader.show('Waiting for screen…');
        }
        console.debug('video: no remote');
    }

    this.hasRemoteVideo = function () {
        // Stream track is up, but H.264/Janus may still show a white frame until the first IDR
        // with real UI content. Keep the placeholder until a non-blank frame is painted.
        console.debug('video: has remote track — waiting for painted content');
        this._startWaitingForPaint();
    }

    this.setStreamingPluginHandle = function(streaming){
        this.streaming = streaming;
    }

    this.setResolution = function(w, h){
        this.videoResolution = [w, h];
        this.remoteVideoElem.attr('width', w).attr('height', h);
    }

    this.setStream = function (stream) {
        let streamChanged = false;
        if (this.stream !== stream) {
            this.stream = stream;
            streamChanged = true;
        }

        if (this.getStreamVideotracks().length > 0) {
            if (streamChanged) {
                Janus.attachMediaStream(this.remoteVideoElem.get(0), this.stream);
            }
            this.hasRemoteVideo();
            if (['chrome', 'firefox', 'safari'].indexOf(Janus.webRTCAdapter.browserDetails.browser) >= 0) {
                this.videoStats.start();
            }
        } else {
            this.noRemoteVideo();
            this.videoStats.stop();
        }
    }

    this.startStreamMountpoint = function (mountpointId, pin) {
        this.mountpointId = mountpointId;
        console.info("streaming: starting mountpoint id " + mountpointId + ' with pin ' + pin);

        var body = {"request": "watch", "id": mountpointId, "pin": pin};
        this.streaming.send({"message": body});
        this.noRemoteVideo();
    }

    this.remoteVideoElem.on("playing", function (e) {
        console.debug('video: playing event', e);

        if (obj.getStreamVideotracks().length > 0) {
            obj.videoStats.start();
            var el = obj.remoteVideoElem.get(0);
            if (el.videoWidth && el.videoHeight) {
                obj.setResolution(el.videoWidth, el.videoHeight);
            }
            // Do not mark ready / hide loader here — wait for non-blank paint.
            if (obj._waitingForPaint) {
                obj._revealVideoIfReady();
            }
        } else {
            obj.videoStats.stop();
        }
    });

    this.stopStreaming = function () {
        console.info('video: stopping streaming');
        this.streaming.send({"message": {"request": "stop"}});
        this.streaming.hangup();
        this.cleanup();
    }

    this.cleanup = function () {
        console.info('video: cleanup ..');
        this._stopFrameProbe();
        this.isVideoAlreadyPlayed = false;
        this.videoStats.stop();
    }
}
