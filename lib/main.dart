import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const WaterMeterApp());
}

class WaterMeterApp extends StatelessWidget {
  const WaterMeterApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Meter IoT',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Bluetooth state
  BluetoothConnection? connection;
  bool isConnecting = false;
  bool isConnected = false;
  List<BluetoothDevice> devices = [];
  
  // Data from device
  double currentFlowRate = 0.0;
  double totalVolume = 0.0;
  List<Map<String, dynamic>> logData = [];
  
  // WiFi settings
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  
  // Stream subscription for incoming data
  StreamSubscription<Uint8List>? dataSubscription;
  
  // Buffer for incomplete messages
  String incomingDataBuffer = '';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _startBluetoothDiscovery();
  }

  @override
  void dispose() {
    dataSubscription?.cancel();
    connection?.dispose();
    ssidController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();
  }

  Future<void> _startBluetoothDiscovery() async {
    try {
      devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      setState(() {});
    } catch (e) {
      _showSnackBar('Error discovering devices: $e');
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (isConnected) {
      await _disconnect();
    }

    setState(() {
      isConnecting = true;
    });

    try {
      connection = await BluetoothConnection.toAddress(device.address);
      
      setState(() {
        isConnecting = false;
        isConnected = true;
      });
      
      _showSnackBar('Connected to ${device.name}');
      
      // Listen for incoming data
      dataSubscription = connection!.input!.listen(
        (data) {
          _processIncomingData(String.fromCharCodes(data));
        },
        onDone: () {
          _disconnect();
        },
        onError: (error) {
          _disconnect();
          _showSnackBar('Connection error: $error');
        },
      );
      
      // Request log data after connection
      _sendCommand('GET_LOG');
      
    } catch (e) {
      setState(() {
        isConnecting = false;
      });
      _showSnackBar('Failed to connect: $e');
    }
  }

  Future<void> _disconnect() async {
    dataSubscription?.cancel();
    
    if (connection != null && connection!.isConnected) {
      await connection!.close();
    }
    
    setState(() {
      isConnected = false;
      connection = null;
    });
  }

  void _processIncomingData(String data) {
    // Add incoming data to buffer
    incomingDataBuffer += data;
    
    // Process complete lines
    if (incomingDataBuffer.contains('\n')) {
      List<String> lines = incomingDataBuffer.split('\n');
      
      // Keep the last incomplete line in the buffer
      incomingDataBuffer = lines.removeLast();
      
      for (String line in lines) {
        line = line.trim();
        if (line.isEmpty) continue;
        
        if (line.startsWith('FlowRate:')) {
          _processFlowRateData(line);
        } else if (line.startsWith('[LOG]')) {
          _processLogData(line);
        } else if (line.startsWith('[CMD]')) {
          _showSnackBar(line);
        }
      }
      
      setState(() {});
    }
  }

  void _processFlowRateData(String line) {
    try {
      // Expected format: "FlowRate:X.XX/Lmin, Total:Y.YYL"
      List<String> parts = line.split(',');
      
      String flowPart = parts[0].replaceAll('FlowRate:', '').trim();
      currentFlowRate = double.parse(flowPart.split('/')[0]);
      
      String totalPart = parts[1].replaceAll('Total:', '').replaceAll('L', '').trim();
      totalVolume = double.parse(totalPart);
    } catch (e) {
      print('Error parsing flow rate data: $e');
    }
  }

  void _processLogData(String line) {
    try {
      // Format should be [LOG] followed by JSON
      String jsonStr = line.substring(5).trim();
      Map<String, dynamic> entry = json.decode(jsonStr);
      
      // Check if this is from the log file
      if (entry.containsKey('datetime') && entry.containsKey('flowRate')) {
        logData.add(entry);
      }
    } catch (e) {
      print('Error parsing log data: $e');
    }
  }

  Future<void> _sendCommand(String command) async {
    if (connection != null && connection!.isConnected) {
      connection!.output.add(Uint8List.fromList(utf8.encode('$command\n')));
      await connection!.output.allSent;
    } else {
      _showSnackBar('Not connected to device');
    }
  }

  Future<void> _resetLog() async {
    await _sendCommand('RESET_LOG');
    setState(() {
      logData.clear();
    });
  }

  Future<void> _resetTotal() async {
    await _sendCommand('RESET_TOTAL');
  }

  Future<void> _resetAll() async {
    await _sendCommand('RESET_ALL');
    setState(() {
      logData.clear();
    });
  }

  Future<void> _updateWiFi() async {
    String ssid = ssidController.text;
    String password = passwordController.text;
    
    if (ssid.isEmpty) {
      _showSnackBar('Please enter SSID');
      return;
    }
    
    await _sendCommand('SET_WIFI:$ssid,$password');
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Meter IoT'),
        actions: [
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: _disconnect,
              tooltip: 'Disconnect',
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startBluetoothDiscovery,
              tooltip: 'Refresh devices',
            ),
        ],
      ),
      body: isConnected ? _buildConnectedView() : _buildDeviceListView(),
    );
  }

  Widget _buildDeviceListView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Select your Water Meter device',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        Expanded(
          child: devices.isEmpty
              ? const Center(child: Text('No paired devices found'))
              : ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return ListTile(
                      title: Text(device.name ?? 'Unknown device'),
                      subtitle: Text(device.address),
                      trailing: ElevatedButton(
                        child: isConnecting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Connect'),
                        onPressed: isConnecting
                            ? null
                            : () => _connectToDevice(device),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildConnectedView() {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            tabs: const [
              Tab(text: 'Dashboard'),
              Tab(text: 'Log Data'),
              Tab(text: 'Settings'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildDashboardTab(),
                _buildLogDataTab(),
                _buildSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildMeterCard(
              'Current Flow Rate',
              '$currentFlowRate L/min',
              Icons.water,
              Colors.blue,
            ),
            const SizedBox(height: 24),
            _buildMeterCard(
              'Total Volume',
              '$totalVolume L',
              Icons.water_drop,
              Colors.lightBlue,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeterCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogDataTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Flow Rate History',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
                onPressed: () => _sendCommand('GET_LOG'),
              ),
            ],
          ),
        ),
        Expanded(
          child: logData.isEmpty
              ? const Center(child: Text('No log data available'))
              : ListView.builder(
                  itemCount: logData.length,
                  itemBuilder: (context, index) {
                    final entry = logData[logData.length - 1 - index]; // Reverse order
                    return ListTile(
                      title: Text('${entry['flowRate']} L/min'),
                      subtitle: Text(entry['datetime']),
                      leading: const Icon(Icons.water_drop),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'WiFi Configuration',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: ssidController,
                    decoration: const InputDecoration(
                      labelText: 'WiFi SSID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'WiFi Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _updateWiFi,
                    child: const Text('Update WiFi Settings'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Data Management',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: _resetLog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Reset Log'),
                      ),
                      ElevatedButton(
                        onPressed: _resetTotal,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Reset Total'),
                      ),
                      ElevatedButton(
                        onPressed: _resetAll,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Reset All'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}