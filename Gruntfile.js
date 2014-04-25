/*global module:false*/
module.exports = function (grunt) {

	// load all grunt tasks matching the `grunt-*` pattern
	require('load-grunt-tasks')(grunt);
	grunt.loadNpmTasks("grunt-git-dist");

	grunt.registerTask("build", ["exec:make","copy:dist","urequire","uglify"]);
	grunt.registerTask("default", ["clean:dist","build", "clean:swf"]);
	grunt.registerTask("release", [
		"clean:dist",
		"git-dist:release:clone",
		"build",
		"git-describe",
		"git-dist:release:add",
		"git-dist:release:commit",
		"git-dist:release:push"
	]);

	grunt.event.on("git-describe", function(git_version) {
		grunt.config("pkg.version", grunt.config("pkg.version") + "+" + git_version.object);
	});

	// Project configuration.
	grunt.config.init({
		pkg: grunt.file.readJSON('package.json'),
		meta: {
			version: "<%= pkg.version %>",
			banner: "/*! <%= pkg.name %> - <%= pkg.version %> @ <%= grunt.template.today('yyyy-mm-dd HH:MM:ss') %> */"
		},
		clean: {
			"dist": "dist/",
			"swf": "*.swf"
		},
		exec: {
			make: {
				cmd: "make",
				stdout: false,
				stderr: false
			}
		},
		copy: {
			dist: {
				files: [
					{
						expand : true,
						src: ["recorder.js","recorder.swf","require.js", "module.js"],
						dest: "dist"
					}
				]
			}
		},
		urequire: {
			amd: {
				template: "AMD",
				path: 'dist',
				filez: ["recorder.js"],
                // Export global Recorder for bridging flash.
                dependencies: {
                    exports: {
                        root: {
                            "recorder": "Recorder"
                        }
                    }
                },
                resources: [
                    [
                        '+exportsVars',
                        ["recorder.js"],
                        function (m) {
                            m.afterBody = "module.exports = Recorder;"
                        }
                    ]
                ],
                forceOverwriteSources: true
			}
		},
		uglify: {
			dist: {
				src: [ "<banner>", "dist/recorder.js" ],
				dest: "dist/recorder.min.js"
			}
		},
		"git-describe": {
			bundle: {}
		},
		bump: {
			options: {
				commitMessage: 'Release v%VERSION%',
				createTag: true,
				tagName: 'v%VERSION%',
				tagMessage: 'Version %VERSION%',
				push: true,
				pushTo: 'origin',
				// options to use with '$ git describe'
				gitDescribeOptions: '--tags --always --abbrev=1 --dirty=-d'
			}
		},
		"git-dist" : {
			"release" : {
				"options" : {
					"branch" : "dist",
					"dir" : "dist",
					"message" : "Built <%= pkg.name %> - <%= pkg.version %>"
				}
			}
		}
	});


};
