'use strict';

function setupWS($scope, $timeout) {
  var protocol = "";
  if (document.location.protocol === "https:") {
    protocol = "wss:";
  } else {
    protocol = "ws:";
  }
  var ws       = new WebSocket(protocol + '//' + window.location.host + "/ws");

  ws.onopen    = function()  {
    $scope.connected = true;
    console.log('websocket opened');
  };

  ws.onclose   = function()  {
    console.log("Websocket closed");
    $scope.connected = false;
    $scope.local_files = [];
    $scope.files = {};
    $timeout(function () {
      setupWS($scope);
    }, 2000);
  };

  ws.onmessage = function(m) {
    console.log('websocket message: ' +  m.data);
    var msg = JSON.parse(m.data);
    $scope.$apply(function () {
      $scope.handle_msg(msg);
    })
  };

  window.ws = ws;
}

function addFilesToStore($scope, files) {
  for (var i=0, file; file=files[i]; i++) {
    if (file.size < 5*1024*1024) {
      addFileToStore($scope, file);
    } else {
      console.error("File size to high : " + file.size);
      alert("File size to high : " + file.size);
    }
  }
}

function addFileToStore($scope, file) {
  $scope.local_files.push(file);
  console.log("add file to store");
  var reader = new FileReader();
  reader.onload = function(e) {
    console.log("file loaded");
    console.log("size : " + file.size);
    console.log("data size : " + e.target.result.length);

    var fileStorage = JSON.stringify({
        name: file.name,
        size: file.size,
        type: file.type,
        data: btoa(e.target.result)
    });

    var fileRegister = JSON.stringify({
        type: "register_file",
        name: file.name,
        content_type: file.type,
        size: file.size
    });
    try {
      sessionStorage[file.name] = fileStorage;
    } catch(e) {
      alert("File is too big");
    }
    ws.send(fileRegister);
  };
  reader.readAsBinaryString(file);
};

function setupFileDrop($scope) {
  var dropZone = document.getElementById('dropZone');

    // Optional.   Show the copy icon when dragging over.  Seems to only work for chrome.
    dropZone.addEventListener('dragover', function(e) {
        e.stopPropagation();
        e.preventDefault();
        $scope.dragdrop = true;
        dropZone.style.border = '3px dashed red';
        e.dataTransfer.dropEffect = 'copy';
    });

    dropZone.addEventListener('dragenter', function(e) {
                dropZone.style.border = '3px dashed red';
                return false;
    });

    dropZone.addEventListener('dragleave', function(e) {
                e.preventDefault();
                e.stopPropagation();
                dropZone.style.border = '0';
                return false;
    });

    // Get file data on drop
    dropZone.addEventListener('drop', function(e) {
        e.stopPropagation();
        e.preventDefault();
        dropZone.style.border = '0';
        var files = e.dataTransfer.files; // Array of all files
        addFilesToStore($scope, files);
        return false;
    });
};

var myApp = angular.module('shareApp', ['ui.router', 'monospaced.qrcode']);

myApp.config(function($stateProvider, $urlRouterProvider) {

  $urlRouterProvider.otherwise("/");

  $stateProvider
    .state('home', {
      url: "/",
      templateUrl: "files.html",
      controller: function($scope, $timeout) {

        $scope.files = [];
        $scope.local_files = [];
        $scope.connected = false;
        $scope.dragdrop = true;
        $scope.downloadhost = document.location.protocol + "//" + document.location.host;

        function handle_stream(msg) {
          console.log("Should stream file " + msg.name)
          var file = JSON.parse(sessionStorage[msg.name]);
          ws.send(JSON.stringify({
            type: "chunk",
            uuid: msg.uuid,
            chunk: file.data
          }));
        }

        function handle_files(files) {
            console.log(files);
            $scope.files = files;
        };

        $scope.handle_msg = function(msg) {
          switch(msg.type) {
            case "files": handle_files(msg.files); break;
            case "hello": console.log("Hello : " + msg.text); break;
            case "stream": handle_stream(msg); break;
            default: console.error("Unknown message" + msg.type);
          }
        };

        setupWS($scope, $timeout);
        setupFileDrop($scope);
        $('.message .close')
        .on('click', function() {
          $(this)
          .closest('.message')
          .hide()
          //.transition('fade')
          ;
        });
        $('div.file-upload').on('click', function () {
          $('input.file-upload').val(null).click();

        });
        $('input.file-upload').on('change', function () {
          addFilesToStore($scope, $(this).prop('files'));
        });
      }
    });
  });
