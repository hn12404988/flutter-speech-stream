part of sound_stream;

class Speech {
  final Uint8List data;
  final DateTime recordedTime;
  final int date;

  Speech({
    required this.data, required this.recordedTime, required this.date,
  });

  Speech.init(): data=Uint8List(0), recordedTime=DateTime.now(),
        date=0;

  bool get isInit => data.length == 0;

  Int16List get int16List => Int16List.view(data.buffer);

  static int get8DigitDate(final DateTime time) {
    return time.year * 10000 + time.month * 100 + time.day;
  }
}

class RecorderStream {
  static final RecorderStream _instance = RecorderStream._internal();
  factory RecorderStream() => _instance;

  final _audioStreamController = StreamController<Speech>.broadcast();
  final _rawAudioStreamController = StreamController<Speech>.broadcast();

  final _recorderStatusController =
      StreamController<SoundStreamStatus>.broadcast();

  DateTime _preRecordedTime = DateTime.now();
  Uint8List? _data;
  Uint8List? _rawData;

  RecorderStream._internal() {
    SoundStream();
    _eventsStreamController.stream.listen(_eventListener);
    _recorderStatusController.add(SoundStreamStatus.Unset);
    _audioStreamController.add(Speech.init());
    _rawAudioStreamController.add(Speech.init());
  }

  int _getDate(DateTime recorded) {
    final preDate = Speech.get8DigitDate(_preRecordedTime);
    final thisDate = Speech.get8DigitDate(recorded);
    if (preDate == thisDate) return thisDate;
    // we are crossing the midnight (12am)
    final gap = recorded.difference(_preRecordedTime).abs().inSeconds;
    // If > 1 minute, then we cross the date
    if (gap >= 60) {
      return thisDate;
    } else {
      return preDate;
    }
  }

  /// Initialize Recorder with specified [sampleRate]
  Future<dynamic> initialize({int sampleRate = 16000, bool showLogs = false}) =>
      _methodChannel.invokeMethod<dynamic>("initializeRecorder", {
        "sampleRate": sampleRate,
        "showLogs": showLogs,
      });

  /// Start recording. Recorder will start pushing audio chunks (PCM 16bit data)
  /// to audiostream as Uint8List
  Future<dynamic> start() =>
      _methodChannel.invokeMethod<dynamic>("startRecording");

  /// Recorder will stop recording and sending audio chunks to the [audioStream].
  Future<dynamic> stop() =>
      _methodChannel.invokeMethod<dynamic>("stopRecording");

  /// Current status of the [RecorderStream]
  Stream<SoundStreamStatus> get status => _recorderStatusController.stream;

  /// Stream of PCM 16bit data from Microphone
  Stream<Speech> get audioStream => _audioStreamController.stream;

  /// Stream of PCM 16bit data from Microphone
  Stream<Speech> get rawAudioStream => _rawAudioStreamController.stream;

  DateTime? _tryParseRecordedTime(dynamic seconds) {
    if (!(seconds is int)) {
      return null;
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(seconds);
    } catch(e) {
      // TODO: something wrong
      return null;
    }
  }

  void _eventListener(dynamic event) {
    if (event == null) return;
    final String eventName = event["name"] ?? "";
    switch (eventName) {
      case "dataPeriod":
        final Uint8List audioData = Uint8List.fromList(event["data"]);
        if (audioData.isNotEmpty) {
          _data = audioData;
        }
        break;
      case "dataTime":
        if (_data == null) {
          // TODO: something wrong
        } else {
          final recordedTime = _tryParseRecordedTime(event["data"]);
          if (recordedTime != null) {
            _audioStreamController.add(
                Speech(
                    data: _data!,
                    recordedTime: recordedTime,
                    date: _getDate(recordedTime)
                )
            );
            _preRecordedTime = recordedTime;
          }
        }
        _data = null;
        break;
      case "rawPeriod":
        final Uint8List audioData = Uint8List.fromList(event["data"]);
        if (audioData.isNotEmpty) {
          _rawData = audioData;
        }
        break;
      case "rawDataTime":
        if (_rawData == null) {
          // TODO: something wrong
        } else {
          final recordedTime = _tryParseRecordedTime(event["data"]);
          if (recordedTime != null) {
            _rawAudioStreamController.add(
                Speech(
                    data: _rawData!,
                    recordedTime: recordedTime,
                    date: _getDate(recordedTime),
                )
            );
            _preRecordedTime = recordedTime;
          }
        }
        _rawData = null;
        break;
      case "recorderStatus":
        final String status = event["data"] ?? "Unset";
        _recorderStatusController.add(SoundStreamStatus.values.firstWhere(
          (value) => _enumToString(value) == status,
          orElse: () => SoundStreamStatus.Unset,
        ));
        break;
    }
  }

  /// Stop and close all streams. This cannot be undone
  /// Only call this method if you don't want to use this anymore
  void dispose() {
    stop();
    _eventsStreamController.close();
    _recorderStatusController.close();
    _rawAudioStreamController.close();
    _audioStreamController.close();
  }
}
