import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_windows/ble_midi_device.dart';
import 'package:flutter_midi_command_windows/windows_midi_device.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:win32/win32.dart';
import 'package:flutter_midi_command_windows/device_monitor.dart';

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  StreamController<MidiPacket> _rxStreamController = StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController = StreamController<String>.broadcast();
  late Stream<String> _setupStream;

  StreamController<String> _bluetoothStateStreamController = StreamController<String>.broadcast();
  late Stream<String> _bluetoothStateStream;

  Map<String, WindowsMidiDevice> _connectedDevices = Map<String, WindowsMidiDevice>();

  // BLE Vars

  String _bleState = "unknown";
  Map<String, BLEMidiDevice> _discoveredBLEDevices = {};

  factory FlutterMidiCommandWindows() {
    if (_instance == null) {
      _instance = FlutterMidiCommandWindows._();
    }
    return _instance!;
  }

  static FlutterMidiCommandWindows? _instance;

  FlutterMidiCommandWindows._() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _bluetoothStateStream = _bluetoothStateStreamController.stream;

    final dm = DeviceMonitor();
    dm.messages.listen((message) {
      if (["deviceAppeared", "deviceDisappeared"].contains(message.event)) {
        _setupStreamController.add(message.event);
      }
    });
  }

  /// The windows implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for windows
  static void registerWith() {
    print("register FlutterMidiCommandWindows");
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  //#region
  @override
  Future<List<MidiDevice>> get devices async {
    var devices = Map<String, MidiDevice>();

    Pointer<MIDIINCAPS> inCaps = malloc<MIDIINCAPS>();
    int nMidiDeviceNum = midiInGetNumDevs();

    Map<String, int> deviceInputs = {};

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      var name = inCaps.ref.szPname;
      var id = name;

      if (!deviceInputs.containsKey(name)) {
        deviceInputs[name] = 0;
      } else {
        deviceInputs[name] = deviceInputs[name]! + 1;
      }

      if (deviceInputs[name]! > 0) {
        id = id + " (${deviceInputs[name]})";
      }

      bool isConnected = _connectedDevices.containsKey(id);
      print('found IN at i $i id $id for device $name');
      devices[id] = WindowsMidiDevice(id, name, _rxStreamController, _setupStreamController, _midiCB.nativeFunction.address)
        ..addInput(i, inCaps.ref)
        ..connected = isConnected;
    }

    free(inCaps);

    Pointer<MIDIOUTCAPS> outCaps = malloc<MIDIOUTCAPS>();
    nMidiDeviceNum = midiOutGetNumDevs();

    Map<String, int> deviceOutputs = {};

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      var name = outCaps.ref.szPname;
      var id = name;

      if (!deviceOutputs.containsKey(name)) {
        deviceOutputs[name] = 0;
      } else {
        deviceOutputs[name] = deviceOutputs[name]! + 1;
      }

      if (deviceOutputs[name]! > 0) {
        id = id + " (${deviceOutputs[name]})";
      }

      if (devices.containsKey(id)) {
        print('add OUT at i $i id $id for device $name}');

        // Add to existing device
        devices[id]! as WindowsMidiDevice..addOutput(i, outCaps.ref);
      } else {
        print('found OUT at i $i id $id for device $name');

        bool isConnected = _connectedDevices.containsKey(id);
        devices[id] = WindowsMidiDevice(id, name, _rxStreamController, _setupStreamController, _midiCB.nativeFunction.address)
          ..addOutput(i, outCaps.ref)
          ..connected = isConnected;
      }
    }

    free(outCaps);

    devices.addAll(_discoveredBLEDevices);

    return devices.values.toList();
  }

  /// Prepares Bluetooth system
  @override
  Future<void> startBluetoothCentral() async {
    UniversalBle.timeout = const Duration(seconds: 10);

    UniversalBle.onAvailabilityChange = (state) {
      debugPrint("ble state " + state.name);
      _bleState = state.name;
      _bluetoothStateStreamController.add(state.name);
    };

    UniversalBle.onScanResult = (result) {
      if (!_discoveredBLEDevices.containsKey(result.deviceId)) {
        if (result.name != null) {
          debugPrint("${result.name} ${result.deviceId} ${result.manufacturerData}");
          _discoveredBLEDevices[result.deviceId] = BLEMidiDevice(result.deviceId, result.name!, _rxStreamController);
          _setupStreamController.add('deviceAppeared');
        }
      }
    };

    UniversalBle.onConnectionChanged = (deviceId, state) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        if (state == BleConnectionState.connected) {
          _discoveredBLEDevices[deviceId]!.connectionState = state;
          _setupStreamController.add('deviceConnected');
        } else {
          _discoveredBLEDevices.remove(deviceId);
          _setupStreamController.add('deviceDisconnected');
        }
      }
    };

    UniversalBle.onValueChanged = (deviceId, characteristicId, Uint8List data) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        _discoveredBLEDevices[deviceId]!.handleData(data);
      }
    };

    UniversalBle.onPairingStateChange = (deviceId, state, msg) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        _discoveredBLEDevices[deviceId]!.pairingState = state;
      }
    };
  }

  /// Stream firing events whenever a change in bluetooth central state happens
  @override
  Stream<String>? get onBluetoothStateChanged {
    return _bluetoothStateStream;
  }

  /// Returns the current state of the bluetooth subsystem
  @override
  Future<String> bluetoothState() async {
    return _bleState;
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    try {
      await UniversalBle.startScan();
    } catch (e) {
      print(e.toString());
    }
  }

  @override
  void stopScanningForBluetoothDevices() {
    /// Stops scanning for BLE MIDI devices.
    print("stop scan");
    UniversalBle.stopScan();
  }

  /// Connects to the device.
  @override
  Future<void> connectToDevice(MidiDevice device, {List<MidiPort>? ports}) async {
    if (device is WindowsMidiDevice) {
      var success = device.connect();
      if (success) {
        _connectedDevices[device.id] = device;
        print("$_connectedDevices");
      } else {
        print("failed to connect $device");
      }
    } else if (device is BLEMidiDevice) {
      device.connect();
    }
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (device is WindowsMidiDevice) {
      if (_connectedDevices.containsKey(device.id)) {
        var windowsDevice = _connectedDevices[device.id]!;
        var result = windowsDevice.disconnect();
        print(result);
        if (result) {
          _connectedDevices.remove(device.id);
          _setupStreamController.add("deviceDisconnected");
        } else {
          print("failed to close $windowsDevice");
        }
      }
    } else if (device is BLEMidiDevice) {
      device.disconnect();
    }
  }

  @override
  void teardown() {
    // Close callback isolate
    _midiCB.close();

    DeviceMonitor().destroy();

    _connectedDevices.values.forEach((device) {
      disconnectDevice(device, remove: false);
    });
    _connectedDevices.clear();
    _setupStreamController.add("deviceDisconnected");
    _rxStreamController.close();
    print("Teardown done");
  }

  /// Sends data to the currently connected devices or a specific midi device
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      // Send to specific device, if present
      _connectedDevices[deviceId]?.send(data);

      _discoveredBLEDevices.values.where((element) => element.deviceId == deviceId).forEach((element) {
        element.send(data);
      });
    } else {
      // Send to all devices
      _connectedDevices.values.forEach((device) {
        device.send(data);
      });

      _discoveredBLEDevices.values.where((element) => element.connected).forEach((element) {
        element.send(data);
      });
    }
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived {
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String>? get onMidiSetupChanged {
    return _setupStream;
  }

  /// Creates a virtual MIDI source
  ///
  /// The virtual MIDI source appears as a virtual port in other apps.
  /// Currently only supported on iOS.
  @override
  void addVirtualDevice({String? name}) {
    // Not implemented
    print('addVirtualDevice Not implemented on Windows');
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    // Not implemented
    print('removeVirtualDevice Not implemented on Windows');
  }

  @override
  Future<bool?> get isNetworkSessionEnabled async {
    return false;
  }

  @override
  void setNetworkSessionEnabled(bool enabled) {
    // Not implemented
    print('setNetworkSessionEnabled Not implemented on Windows');
  }

  WindowsMidiDevice? findMidiDeviceForSource(int src) {
    for (WindowsMidiDevice wmd in _connectedDevices.values) {
      if (wmd.containsMidiIn(src)) {
        return wmd;
      }
    }
    return null;
  }
  //#endregion
}

String midiErrorMessage(int status) {
  switch (status) {
    case MMSYSERR_ALLOCATED:
      return "Resource already allocated";
    case MMSYSERR_BADDEVICEID:
      return "Device ID out of range";
    case MMSYSERR_INVALFLAG:
      return "Invalid dwFlags";
    case MMSYSERR_INVALPARAM:
      return 'Invalid pointer or structure';
    case MMSYSERR_NOMEM:
      return "Unable to allocate memory";
    case MMSYSERR_INVALHANDLE:
      return "Invalid handle";
    default:
      return "Status $status";
  }
}

NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)> _midiCB = NativeCallable<MidiInProc>.listener(_onMidiData);

void _onMidiData(int hMidiIn, int wMsg, int dwInstance, int dwParam1, int dwParam2) {
  //print('midi data $hMidiIn, $wMsg, $dwInstance, $dwParam1, $dwParam2');

  var dev = FlutterMidiCommandWindows().findMidiDeviceForSource(hMidiIn);

  switch (wMsg) {
    case MIM_OPEN:
      print("port opened");
      dev?.connected = true;
      break;
    case MIM_CLOSE:
      print('port closed');
      dev?.connected = false;
      break;
    case MIM_DATA:
      // print("data! $dwParam1 at: $dwParam2");
      var data = Uint32List.fromList([dwParam1]).buffer.asUint8List();
      dev?.handleData(data, dwParam2);
      break;
    case MIM_LONGDATA:
      var pMidiHdr = Pointer.fromAddress(dwParam1).cast<MIDIHDR>();
      var data = pMidiHdr.ref.lpData.cast<Uint8>().asTypedList(pMidiHdr.ref.dwBytesRecorded);
      dev?.handleSysexData(data);
      break;
    case MIM_MOREDATA:
      print("More data - unhandled!");
      break;
    case MIM_ERROR:
      print("Error");
      break;
    case MIM_LONGERROR:
      print("Long error");
      break;
  }
}
