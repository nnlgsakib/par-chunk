import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const DownloaderApp());
}

class DownloaderApp extends StatelessWidget {
  const DownloaderApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Par-Chunk(Developed BY NLG)',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        cardColor: const Color(0xFF2A2A2A),
      ),
      home: const DownloaderHome(),
    );
  }
}

class DownloaderHome extends StatefulWidget {
  const DownloaderHome({Key? key}) : super(key: key);

  @override
  _DownloaderHomeState createState() => _DownloaderHomeState();
}

class _DownloaderHomeState extends State<DownloaderHome> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _chunksController = TextEditingController();
  String _outputPath = '';
  bool _isDownloading = false;
  double _progress = 0.0;
  Map<int, double> _chunkProgress = {};
  Map<int, int> _chunkSizes = {};
  String _estimatedTimeRemaining = '';
  double _downloadSpeed = 0.0;
  Timer? _speedUpdateTimer;
  int _lastBytesDownloaded = 0;
  int _totalBytesDownloaded = 0;
  int _totalExpectedBytes = 0;
  List<String> _statusLogs = [];

  @override
  void initState() {
    super.initState();
    _chunksController.text = '100';
  }

  void _addStatusLog(String message) {
    if (mounted) {
      setState(() {
        _statusLogs.add(message);
      });
    }
  }

  Future<void> _pickOutputLocation() async {
    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() => _outputPath = path);
    }
  }

  Future<void> _cleanupChunksDirectory() async {
    if (_outputPath.isEmpty) return;

    final chunksDir = Directory('$_outputPath/chunks');
    if (await chunksDir.exists()) {
      await chunksDir.delete(recursive: true);
    }
    await chunksDir.create();
  }

  Future<int?> _getFileSize(String url) async {
    try {
      final response = await http.head(Uri.parse(url));
      return int.tryParse(response.headers['content-length'] ?? '0');
    } catch (e) {
      return null;
    }
  }

  Future<void> _startDownload() async {
    if (_urlController.text.isEmpty || _outputPath.isEmpty) {
      _showError('Please provide URL and output location');
      return;
    }

    if (!Uri.parse(_urlController.text).isAbsolute) {
      _showError('Invalid URL');
      return;
    }

    final chunks = int.tryParse(_chunksController.text) ?? 0;
    if (chunks <= 0) {
      _showError('Number of chunks must be a positive integer');
      return;
    }

    await _cleanupChunksDirectory();

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _chunkProgress.clear();
      _chunkSizes.clear();
      _totalBytesDownloaded = 0;
      _totalExpectedBytes = 0;
      _statusLogs.clear();
    });
    _addStatusLog('Initializing download...');

    final url = _urlController.text;
    final fileSize = await _getFileSize(url);

    try {
      if (fileSize == null || fileSize == 0) {
        await _downloadSingleFile(url);
        return;
      }

      setState(() => _totalExpectedBytes = fileSize);

      _speedUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_lastBytesDownloaded != _totalBytesDownloaded) {
          setState(() {
            _downloadSpeed = (_totalBytesDownloaded - _lastBytesDownloaded) / 1024 / 1024;
            _lastBytesDownloaded = _totalBytesDownloaded;
            _progress = _totalBytesDownloaded / _totalExpectedBytes;
          });
        }
      });

      final chunkSize = fileSize ~/ chunks;
      final List<Future<void>> futures = [];

      for (int i = 0; i < chunks; i++) {
        final start = i * chunkSize;
        final end = i < chunks - 1 ? start + chunkSize - 1 : fileSize - 1;
        final size = end - start + 1;
        setState(() => _chunkSizes[i] = size);
        futures.add(_downloadChunk(url, i, start, end, fileSize));
      }

      await Future.wait(futures);
      _addStatusLog('All chunks downloaded. Starting combination process...');

      await _combineChunks();
    } catch (e) {
      _showError('Download failed: $e');
    } finally {
      _speedUpdateTimer?.cancel();
      setState(() => _isDownloading = false);
    }
  }

  Future<void> _downloadChunk(
      String url, int index, int start, int end, int totalSize) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers['Range'] = 'bytes=$start-$end';
      final response = await client.send(request);

      final chunkFile = File('$_outputPath/chunks/chunk_$index');
      final sink = chunkFile.openWrite();
      int chunkBytesDownloaded = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        chunkBytesDownloaded += chunk.length;
        _totalBytesDownloaded += chunk.length;

        setState(() {
          _chunkProgress[index] = chunkBytesDownloaded / (_chunkSizes[index] ?? 1);
          _estimatedTimeRemaining = _calculateEstimatedTime(
              totalSize, _totalBytesDownloaded, _downloadSpeed);
        });
      }

      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _downloadSingleFile(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      final fileName = url.split('/').last;
      await File('$_outputPath/$fileName').writeAsBytes(response.bodyBytes);
      _addStatusLog('Download completed!');
    } catch (e) {
      _showError('Single file download failed: $e');
    }
  }

  Future<void> _combineChunks() async {
    _addStatusLog('Starting chunk combination process...');
    final fileName = _urlController.text.split('/').last;
    final outputFile = File('$_outputPath/$fileName');
    final sink = outputFile.openWrite();

    final chunks = int.parse(_chunksController.text);

    for (int i = 0; i < chunks; i++) {
      final chunkFile = File('$_outputPath/chunks/chunk_$i');
      if (await chunkFile.exists()) {
        _addStatusLog('Processing chunk ${i + 1}/$chunks...');
        await sink.addStream(chunkFile.openRead());
        await chunkFile.delete();
        _addStatusLog('Chunk ${i + 1}/$chunks processed successfully');
      }
    }

    await sink.close();
    await Directory('$_outputPath/chunks').delete(recursive: true);
    _addStatusLog('All chunks combined successfully!');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File downloaded successfully at $_outputPath/$fileName'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  String _calculateEstimatedTime(int total, int downloaded, double speed) {
    if (speed <= 0) return 'Calculating...';
    final remaining = (total - downloaded) / (speed * 1024 * 1024);
    return remaining < 60 ? '${remaining.toStringAsFixed(0)}s' :
    remaining < 3600 ? '${(remaining / 60).toStringAsFixed(0)}m' :
    '${(remaining / 3600).toStringAsFixed(1)}h';
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
    _addStatusLog('Error: $message');
    setState(() => _isDownloading = false);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Par-Chunk(Developed BY NLG)'),
        backgroundColor: Theme.of(context).primaryColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Download URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chunksController,
                    decoration: const InputDecoration(
                      labelText: 'Number of Chunks',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _pickOutputLocation,
                  child: const Text('Select Output'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Output Path: $_outputPath'),
            const SizedBox(height: 16),
            if (_isDownloading) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('Overall Progress: ${(_progress * 100).toStringAsFixed(1)}%'),
              Text('Speed: ${_downloadSpeed.toStringAsFixed(2)} MB/s'),
              Text('Estimated Time: $_estimatedTimeRemaining'),
              if (_totalExpectedBytes > 0)
                Text('Total Size: ${_formatSize(_totalExpectedBytes)}'),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: int.parse(_chunksController.text),
                  itemBuilder: (context, index) {
                    final chunkSize = _chunkSizes[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Chunk ${index + 1}'),
                              if (chunkSize != null)
                                Text('Size: ${_formatSize(chunkSize)}'),
                            ],
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: _chunkProgress[index] ?? 0,
                            backgroundColor: Colors.grey[800],
                          ),
                          Text(
                            '${((_chunkProgress[index] ?? 0) * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            Expanded(
              child: ListView.builder(
                itemCount: _statusLogs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: Text(_statusLogs[index]),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isDownloading ? null : _startDownload,
              child: Text(_isDownloading ? 'Downloading...' : 'Start Download'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _chunksController.dispose();
    _speedUpdateTimer?.cancel();
    super.dispose();
  }
}