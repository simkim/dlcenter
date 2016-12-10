'use strict';

if (window.File && window.FileReader && window.FileList && window.Blob) {
  // Great success! All the File APIs are supported.
} else {
  alert('The File APIs are not fully supported in this browser.');
}

function setupWS($scope, $timeout, $interval) {
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
    $scope.ping = $interval(function() {
        ws.send(JSON.stringify({
            type: "ping",
        }));
    }, 10000);
  };

  ws.onclose   = function()  {
      console.log("Websocket closed");
      if ($scope.connected) {
        $scope.connected = false;
        $scope.clients = {};
        $interval.cancel($scope.ping);
        $timeout(function () {
            setupWS($scope, $timeout, $interval);
        }, 2000);
      }
  };
  ws.onerror = function() {
    console.log("Websocket error");
    $scope.connected = false;
    $scope.clients = {};
    $timeout(function () {
        setupWS($scope, $timeout, $interval);
    }, 10000);
  }
  ws.onmessage = function(m) {
      console.log('websocket message: ' +  m.data);
      var msg = JSON.parse(m.data);
      $scope.$apply(function () {
          $scope.handle_msg(msg);
      })
  };

  window.ws = ws;
}

function addSharesToStore($scope, files) {
    for (var i=0, file; file=files[i]; i++) {
        if (file.size < 5000*1024*1024) {
            addShareToStore($scope, file);
        } else {
            console.error("File size to high : " + file.size);
            alert("File size to high : " + file.size);
        }
    }
}

function generateUUID() {
    var d = new Date().getTime();
    var uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = (d + Math.random()*16)%16 | 0;
        d = Math.floor(d/16);
        return (c=='x' ? r : (r&0x3|0x8)).toString(16);
    });
    return uuid;
};

function addContentShareToStore($scope, content) {
    console.log("add content to store");
    var uuid = generateUUID();
    console.log("size : " + content.length);
    console.log("uuid : " + uuid);

    $scope.shares[uuid] = {
        name: "clipboard",
        size: content.length,
        type: "text/plain",
        content: content,
    };

    var fileRegister = JSON.stringify({
        type: "register_share",
        uuid: uuid,
        name: "clipboard",
        content: content,
        content_type: "text/plain",
        size: content.length
    });
    ws.send(fileRegister);
};
function addShareToStore($scope, file) {
    console.log("add file to store");
    var uuid = generateUUID();
    console.log("size : " + file.size);
    console.log("uuid : " + uuid);

    $scope.shares[uuid] = {
        name: file.name,
        size: file.size,
        type: file.type,
        uuid: uuid,
        file: file,
    };

    var fileRegister = JSON.stringify({
        type: "register_share",
        uuid: uuid,
        name: file.name,
        content_type: file.type,
        size: file.size
    });
    ws.send(fileRegister);
};

function removeShare($scope, share) {
    delete $scope.shares[share.uuid];
    var fileUnregister = JSON.stringify({
      type: "unregister_share",
      uuid: share.uuid
    });
    ws.send(fileUnregister);
};

function streamChunk(share, stream_uuid, start, length, cb) {
    var reader = new FileReader();
    reader.onload = function(e) {
        // console.log("chunk loaded " + stream_uuid + " ("+start+","+length+")");
        if (length == 0) {
            console.error("can't stream chunk of length 0");
            return;
        }
        if (length != e.target.result.length) {
            console.error("Ask for " + length + " but got ", e.target.result.length);
            return;
        }
        var close = (start+length) == share.file.size;
        ws.send(JSON.stringify({
            type: "chunk",
            uuid: stream_uuid,
            close: close,
            chunk: btoa(e.target.result)
        }));
        if (cb)
            cb(close);
    };
    var blob = share.file.slice(start, start+length);
    reader.readAsBinaryString(blob);
};

function streamShare(share, stream_uuid, cb) {
    console.log("stream share " + stream_uuid + " ("+share.size+")");
    if (share.content) {
        ws.send(JSON.stringify({
            type: "chunk",
            uuid: stream_uuid,
            close: true,
            chunk: btoa(share.content)
        }));
    } else {
        var position = 0;
        function chunkStreamed(done) {
            if (done) {
                if (cb)
                    cb();
                return;
            }
            var start = position;
            var length = Math.min(1024000, share.size-position);
            position+=length;
            streamChunk(share, stream_uuid, start, length, chunkStreamed);
        }
        chunkStreamed(false);
    }
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
        dropZone.style.border = '3px dashed tranparent';
        return false;
    });

    // Get file data on drop
    dropZone.addEventListener('drop', function(e) {
        e.stopPropagation();
        e.preventDefault();
        dropZone.style.border = '0';
        var files = e.dataTransfer.files; // Array of all files
        if (files.length > 0) {
          addSharesToStore($scope, files);
        } else {
          addContentShareToStore($scope, e.dataTransfer.getData("Text"))
        }
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
        controller: function($scope, $timeout, $interval) {

            $scope.remote_shares = [];
            $scope.shares = {}
            $scope.connected = false;
            $scope.dragdrop = true;
            $scope.downloadhost = document.location.protocol + "//" + document.location.host;
            $scope.filesize = filesize;
            function handle_stream(msg) {
                console.log("Should stream file " + msg.share + " to stream " + msg.uuid)
                var share = $scope.shares[msg.share];
                if (share) {
                    streamShare(share, msg.uuid);
                } else {
                    console.log("cant find share " + msg.share + " in shares")
                }
            }

            function handle_shares(shares) {
                console.log(shares);
                $scope.remote_shares = shares;
            };

            $scope.handle_msg = function(msg) {
                switch(msg.type) {
                    case "shares": handle_shares(msg.shares); break;
                    case "hello": console.log("Hello : " + msg.text); break;
                    case "stream": handle_stream(msg); break;
                    default: console.error("Unknown message" + msg.type);
                }
            };

            $scope.remove_share = function (share) {
              removeShare($scope, share);
            }

            $scope.open_modal = function(uuid) {
              $("#modal-"+uuid).modal('show');
            }
            setupWS($scope, $timeout, $interval);
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
            $('#content-share').on('click', function() {
                var text = $('textarea').val();
                if (text.length > 0) {
                    addContentShareToStore($scope, text);
                    $('textarea').val('');
                }

            });
            $('input.file-upload').on('change', function () {
                console.log("input change")
                addSharesToStore($scope, $(this).prop('files'));
            });
        }
    });
});
