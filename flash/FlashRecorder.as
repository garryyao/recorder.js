package {
  import flash.display.Sprite;
  import flash.external.ExternalInterface;
  import flash.system.Security;

public class FlashRecorder extends Sprite {
    public function FlashRecorder() {
      var logger:Logger;
      logger = new Logger();
      // Allows this swf to be hosted on CDN, but ask for permission everytime.
      Security.allowDomain("*");
      ExternalInterface.addCallback("debugLog", logger.debugLog);
      var recorder = new Recorder(logger, true, loaderInfo.bytes);
      recorder.addExternalInterfaceCallbacks();
    }
  }
}
