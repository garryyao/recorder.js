build:
	mxmlc -debug=false -compiler.show-actionscript-warnings=false -static-link-runtime-shared-libraries=true -optimize=true -library-path+=libs -o recorder.swf -file-specs flash/FlashRecorder.as

clean:
	rm recorder.swf
