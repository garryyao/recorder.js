package  
{
	import com.adobe.audio.format.WAVWriter;
	import flash.events.Event;
	import flash.events.HTTPStatusEvent;
	import flash.events.SampleDataEvent;
	import flash.events.StatusEvent;
	import flash.events.TimerEvent;
	import flash.external.ExternalInterface;
	import flash.media.Microphone;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.net.FileReference;
	import flash.system.ApplicationDomain;
	import flash.system.Security;
	import flash.system.SecurityPanel;
	import flash.utils.ByteArray;
	import flash.utils.Timer;
	import flash.utils.getDefinitionByName;
	import flash.utils.getQualifiedClassName;
	import flash.utils.getTimer;
	import flash.external.ExternalInterface;
	
	import fr.kikko.lab.ShineMp3Encoder;
	
	import ru.inspirit.net.MultipartURLLoader;

	
	public class Recorder
	{
		public static const AUDIO_FORMAT_WAV : int = 0;
		public static const AUDIO_FORMAT_MP3 : int = 1;
		public static const RECORD_DATA_TIMEOUT : int = 5;

		private var mainToWorker : Object;
		private var workerToMain : Object;
		private var worker : Object;
		
		private var Worker : *;
		private var WorkerDomain : *;
		private var MessageChannel : *;

		public function Recorder(logger : Logger, useWorkers : Boolean = true, bytes : ByteArray = null)
		{
			this.logger = logger;
			if(useWorkers)
			{
				if(ApplicationDomain.currentDomain.hasDefinition("flash.system.Worker"))
				{
					Worker = getDefinitionByName("flash.system.Worker");
					WorkerDomain = getDefinitionByName("flash.system.WorkerDomain");
					MessageChannel = getDefinitionByName("flash.system.MessageChannel");
				}

				if(Worker)
				{
					if(Worker.current.isPrimordial)
					{
						worker = WorkerDomain.current.createWorker(bytes);
						
						mainToWorker = Worker.current.createMessageChannel(worker);
						worker.setSharedProperty("mainToWorker", mainToWorker);
						
						workerToMain = worker.createMessageChannel(Worker.current);
						workerToMain.addEventListener("channelMessage", messageFromWorker);
						worker.setSharedProperty("workerToMain", workerToMain);

						worker.addEventListener("workerState", workerStateChange);
						worker.start();
					}
					else
					{
						mainToWorker = Worker.current.getSharedProperty("mainToWorker") as MessageChannel;
						mainToWorker.addEventListener("channelMessage", messageFromMain);
						
						workerToMain = Worker.current.getSharedProperty("workerToMain") as MessageChannel;
					}
				}
			}
		}
		
		private var logger : Logger;
		public function addExternalInterfaceCallbacks():void {
			ExternalInterface.addCallback("record", 		this.record);
			ExternalInterface.addCallback("_stop",  		this.stop);
			ExternalInterface.addCallback("_play",          this.play);
			ExternalInterface.addCallback("upload",         this.upload);
			ExternalInterface.addCallback("audioData",      this.audioData);
			ExternalInterface.addCallback("showFlash",      this.showFlash);
			ExternalInterface.addCallback("recordingDuration",     this.recordingDuration);
			ExternalInterface.addCallback("playDuration",     this.playDuration);
			ExternalInterface.addCallback("encode",			this.encode);
			ExternalInterface.addCallback("saveAudioFile",	this.saveAudioFile);

			triggerEvent("initialized", {});
            logger.log("Recorder initialized");
		}

		
		protected var isRecording:Boolean = false;
		protected var isPlaying:Boolean = false;
		protected var microphoneWasMuted:Boolean;
		protected var playingProgressTimer:Timer;
		protected var microphone:Microphone;
		protected var timeoutIdDetectMicrophone:uint;
		protected var buffer:ByteArray = new ByteArray();
		protected var sound:Sound;
		protected var channel:SoundChannel;
		protected var recordingStartTime = 0;
		protected var lastRecordDuration : int = 0;
		protected static var sampleRate = 44.1;
		
		protected var wavData : ByteArray;
		protected var lastEncoding : ByteArray;
		protected var mp3Encoder : ShineMp3Encoder;
		protected var encoding : Boolean;
		protected var lastUploadCall : Array;
		protected function record():void
		{
			if(!microphone){ 
				setupMicrophone();
			}

			microphoneWasMuted = microphone.muted;
			if(microphoneWasMuted){
				logger.log('showFlashRequired');
				triggerEvent('showFlash','');
			}

			buffer = new ByteArray();

			// To avoid microphone error (PepperFlashPlayer.plugin: 0x2A052 is not valid resource ID.)
			microphone.removeEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
			microphone.addEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
		}
		
		protected function recordStop():int
		{
			logger.log('stopRecording');
			flash.utils.clearTimeout(timeoutIdDetectMicrophone);
			isRecording = false;
			triggerEvent('recordingStop', {duration: recordingDuration()});
			microphone.removeEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
			lastRecordDuration = recordingDuration();
			return lastRecordDuration;
		}
		
		protected function encode(audioFormat : int) : void
		{
			if(encoding || buffer.length == 0 || lastRecordDuration <= 0)
				return;

			if(Worker && Worker.current.isPrimordial)
			{
				worker.setSharedProperty("buffer", buffer);
				worker.setSharedProperty("lastRecordDuration", lastRecordDuration);
				mainToWorker.send("encode");
				mainToWorker.send(audioFormat);
				
				if(!lastEncoding && audioFormat == AUDIO_FORMAT_MP3)
				{
					encoding = true;
				}
				
				return;
			}
			
			if(mp3Encoder)
			{
				mp3Encoder.cancel();
			}
			else
			{
				mp3Encoder = new ShineMp3Encoder();
				mp3Encoder.addEventListener(Event.COMPLETE, encodingComplete);
			}
			
			if(!wavData)
			{
				buffer.position = 0;
				wavData = prepareWav();
			}

			if(!lastEncoding && audioFormat == AUDIO_FORMAT_MP3)
			{
				wavData.position = 0;
				mp3Encoder.start(wavData, lastRecordDuration);
				encoding = true;
			}
		}
		
		protected function encodingComplete(event: Event) : void
		{
			encoding = false;
			if(mp3Encoder)
			{
				lastEncoding = mp3Encoder.mp3Data;
				mp3Encoder.wavData = null;
				mp3Encoder.mp3Data = null;
			}
			
			if(!Worker || Worker.current.isPrimordial)
			{
				if(lastUploadCall)
				{
					this.upload.apply(null, lastUploadCall);
					lastUploadCall = null;
				}
			}
			else
			{
				Worker.current.setSharedProperty("mp3Data", lastEncoding);
				workerToMain.send("encodingComplete");
			}
		}
		
		private function messageFromMain(event : Event) : void
		{
			var message : String = mainToWorker.receive() as String;

			switch(message)
			{
				case "encode":
					var audioFormat : int = mainToWorker.receive() as int;
					buffer = Worker.current.getSharedProperty("buffer") as ByteArray;
					lastRecordDuration = Worker.current.getSharedProperty("lastRecordDuration") as int;
					encode(audioFormat);
					break;
				case "cancel":
					wavData = null;
					if(mp3Encoder)
						mp3Encoder.cancel();
					lastEncoding = null;
					encoding = false;
					break;
			}
		}
		
		private function messageFromWorker(event : Event) : void
		{
			var message : String = workerToMain.receive().toString();
			
			switch(message)
			{
				case "encodingComplete":
					lastEncoding = worker.getSharedProperty("mp3Data") as ByteArray;
					encodingComplete(null);
			}
		}
		
		private function workerStateChange(event : Event) : void
		{
			
		}
		
		public function saveAudioFile() : void
		{
			if(lastEncoding)
				(new FileReference()).save(lastEncoding, "audio.mp3");
		}
		
		protected function play():void
		{
			logger.log('startPlaying');
			isPlaying = true;
			triggerEvent('playingStart', {});
			buffer.position = 0;
			sound = new Sound();
			sound.addEventListener(SampleDataEvent.SAMPLE_DATA, playSampleDataHandler);
			
			channel = sound.play();
			channel.addEventListener(Event.SOUND_COMPLETE, function(){
				playStop();
			});  
			
			if(playingProgressTimer){
				playingProgressTimer.reset();
			}
			playingProgressTimer = new Timer(250);
			var that = this;
			playingProgressTimer.addEventListener(TimerEvent.TIMER, function playingProgressTimerHandler(event:TimerEvent){
				triggerEvent('playingProgress', that.playDuration());
			});
			playingProgressTimer.start();
		}
		
		protected function stop():int
		{
			playStop();
			return recordStop();
		}
		
		protected function playStop():void
		{
			logger.log('stopPlaying');
			if(channel){
				channel.stop();
				playingProgressTimer.reset();
				
				triggerEvent('playingStop', {});
				isPlaying = false;
			}
		}
		
		/* Networking functions */ 
		
		protected function upload(uri:String, audioParam:String, parameters, format : int = 0): void
		{
			if(format == AUDIO_FORMAT_MP3 && encoding)
			{
				lastUploadCall = [uri, audioParam, parameters, format];
				return;
			}
			logger.log("upload");
			buffer.position = 0;
			var ml:MultipartURLLoader = new MultipartURLLoader();
			ml.addEventListener(HTTPStatusEvent.HTTP_STATUS, handleError);
			ml.addEventListener(Event.COMPLETE, onReady);
			function onReady(e:Event):void
			{
				triggerEvent('uploadSuccess', externalInterfaceEncode(e.target.loader.data));
				logger.log('uploading done');
			}

			function handleError(e:HTTPStatusEvent):void
			{
				if(e.status !== 200){
					triggerEvent('uploadFailure', e.status);
					logger.log('uploading failed');
				}
			}

			if(getQualifiedClassName(parameters.constructor) == "Array"){
				for(var i=0; i<parameters.length; i++){
					ml.addVariable(parameters[i][0], parameters[i][1]);
				}
			}else{
				for(var k in parameters){
					ml.addVariable(k, parameters[k]);
				}
			}

			var fileName : String;
			if(format == AUDIO_FORMAT_MP3 && lastEncoding)
			{
				fileName = "audio.mp3";
				ml.addFile(lastEncoding, fileName, audioParam, "audio/mpeg");
				ml.load(uri, false);
			}
			else
			{
				fileName = "audio.wav";
				if(!wavData)
					wavData = prepareWav();
				ml.addFile(wavData, fileName, audioParam, "audio/wave");
				ml.load(uri, false);
			}
			
		}
		
		private function externalInterfaceEncode(data:String){
			return data.split("%").join("%25").split("\\").join("%5c").split("\"").join("%22").split("&").join("%26");
		}
		
		protected function audioData(newData:String=null):String
		{
			var delimiter = ";"
			if(newData){
				buffer = new ByteArray();
				var splittedData = newData.split(delimiter);
				for(var i=0; i < splittedData.length; i++){
					buffer.writeFloat(parseFloat(splittedData[i]));
				}
				return "";
			}else{
				var ret:String="";
				buffer.position = 0;
				while (buffer.bytesAvailable > 0)
				{
					ret += buffer.readFloat().toString() + delimiter;
				}
				return ret;
			}
		}
		
		protected function showFlash():void
		{
			Security.showSettings(SecurityPanel.PRIVACY);
			triggerEvent('showFlash','');	
		}
		
		/* Recording Helper */ 
		protected function setupMicrophone():void
		{
			logger.log('setupMicrophone');
			microphone = Microphone.getMicrophone();
			microphone.codec = "Nellymoser";
			microphone.setSilenceLevel(0);
			microphone.rate = sampleRate;
			microphone.gain = 100;
			microphone.addEventListener(StatusEvent.STATUS, function statusHandler(e:Event) {
				logger.log('Microphone Status Change');
				if(microphone.muted){
					triggerEvent('recordingCancel','');
				}
				else {
					if (microphoneWasMuted) {
						microphoneWasMuted = false;
						triggerEvent('hideFlash', '');
					}
          timeoutIdDetectMicrophone = flash.utils.setTimeout(function () {
						if (!isRecording) {
							microphone.removeEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
							triggerEvent('recordingCancel', '');
						}
					}, RECORD_DATA_TIMEOUT * 1000);
				}
			});

			logger.log('setupMicrophone done: ' + microphone.name + ' ' + microphone.muted);
		}
		
		protected function notifyRecordingStarted():void
		{
			flash.utils.clearTimeout(timeoutIdDetectMicrophone);
			recordingStartTime = getTimer();
			triggerEvent('recordingStart', {});
			logger.log('startRecording');
			isRecording = true;
			
			wavData = null;
			lastEncoding = null;
			if(mp3Encoder)
				mp3Encoder.cancel();
			encoding = false;
			lastUploadCall = null;
			
			if(Worker)
				mainToWorker.send("cancel");
		}
		
		/* Sample related */
		
		protected function prepareWav():ByteArray
		{
			var wavData:ByteArray = new ByteArray();
			var wavWriter:WAVWriter = new WAVWriter(); 
			buffer.position = 0;
			wavWriter.numOfChannels = 1; // set the inital properties of the Wave Writer 
			wavWriter.sampleBitRate = 16; 
			wavWriter.samplingRate = sampleRate * 1000;
			wavWriter.processSamples(wavData, buffer, sampleRate * 1000, 1);
			return wavData;
		}
		
		protected function recordingDuration():int
		{
			var duration = int(getTimer() - recordingStartTime);
			return Math.max(duration, 0);
		}

		protected function playDuration():int
		{
			return int(channel.position);
		}
		
		protected function recordSampleDataHandler(event:SampleDataEvent):void
		{
			if(!isRecording)
				notifyRecordingStarted();

			while (event.data.bytesAvailable) {
				var sample:Number = event.data.readFloat();
				buffer.writeFloat(sample);
				if (buffer.length % 40000 == 0) {
					triggerEvent('recordingProgress', recordingDuration(), microphone.activityLevel);
				}
			}
		}
		
		protected function playSampleDataHandler(event:SampleDataEvent):void
		{
			var expectedSampleRate = 44.1;
			var writtenSamples = 0;
			var channels : int = 2;
			var maxSamples : int = 8192 * channels;
			// if the sampleRate doesn't match the expectedSampleRate of flash.media.Sound (44.1) write the sample multiple times
			// this will result in a little down pitchshift.
			// also write 2 times for stereo channels
			while(writtenSamples < maxSamples && buffer.bytesAvailable)
			{
				var sample:Number = buffer.readFloat();
			  for (var j:int = 0; j < channels * (expectedSampleRate / sampleRate); j++){
					event.data.writeFloat(sample);
					writtenSamples++;
					if(writtenSamples >= maxSamples){
						break;
					}
				}
			}
			logger.log("Wrote " + writtenSamples + " samples");
		}
		
		/* ExternalInterface Communication */
		
		protected function triggerEvent(eventName:String, arg0:*, arg1:* = null):void
		{
			ExternalInterface.call("Recorder.triggerEvent", eventName, arg0, arg1);
		}
	}
}
