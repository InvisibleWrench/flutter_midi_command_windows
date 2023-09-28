import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  StreamController<MidiPacket> _rxStreamController =
  StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController =
  StreamController<String>.broadcast();
  late Stream<String> _setupStream;

  Map<String, WindowsMidiDevice> _connectedDevices =
  Map<String, WindowsMidiDevice>();

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
  }

  /// The windows implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for windows
  static void registerWith() {
    print("register FlutterMidiCommandWindows");
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    var devices = Map<String, WindowsMidiDevice>();

    Pointer<MIDIINCAPS> inCaps = calloc<MIDIINCAPS>();
    int nMidiDeviceNum = midiInGetNumDevs();

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      var name = inCaps.ref.szPname;
      bool isConnected = _connectedDevices.containsKey(name);
      print(
          'found IN at id $i for device $name address: ${inCaps.address} ref: ${inCaps.ref.hashCode} wMid ${inCaps.ref.wMid} wPid ${inCaps.ref.wPid}');
      devices[name] = WindowsMidiDevice(name, _rxStreamController,
          _setupStreamController, _cb.nativeFunction.address)
        ..addInput(i, inCaps.ref)
        ..connected = isConnected;
    }

    free(inCaps);

    Pointer<MIDIOUTCAPS> outCaps = calloc<MIDIOUTCAPS>();
    nMidiDeviceNum = midiOutGetNumDevs();

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      var name = outCaps.ref.szPname;
      print(
          'found OUT at id $i for device $name address: ${outCaps.address} ref: ${outCaps.ref.hashCode} wMid ${outCaps.ref.wMid} wPid ${outCaps.ref.wPid}');

      if (devices.containsKey(name)) {
        // Add to existing device
        devices[name]!..addOutput(i, outCaps.ref);
      } else {
        bool isConnected = _connectedDevices.containsKey(name);
        devices[name] = WindowsMidiDevice(name, _rxStreamController,
            _setupStreamController, _cb.nativeFunction.address)
          ..addOutput(i, outCaps.ref)
          ..connected = isConnected;
      }
    }

    free(outCaps);

    return devices.values.toList();
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    // Not implemented
  }

  /// Stops scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {
    // Not implemented
  }

  /// Connects to the device.
  @override
  Future<void> connectToDevice(MidiDevice device,
      {List<MidiPort>? ports}) async {
    print('connect to [${device.id}] ${device.name}');
    var midiDevice = device as WindowsMidiDevice;
    var success = midiDevice.connect();
    if (success) {
      print("add $midiDevice to connectedDevices");
      _connectedDevices[device.id] = midiDevice;
      print("$_connectedDevices");
    } else {
      print("failed to connect $midiDevice");
    }
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
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
  }

  @override
  void teardown() {
    // Close callback isolate
    _cb.close();

    _connectedDevices.values.forEach((device) {
      disconnectDevice(device, remove: false);
    });
    _connectedDevices.clear();
    _setupStreamController.add("deviceDisconnected");
    _rxStreamController.close();
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    print("send data $data");
    print("${_connectedDevices}");
    _connectedDevices.values.forEach((device) {
      print("send to $device");
      device.send(data);
    });
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
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    // Not implemented
  }

  WindowsMidiDevice? findMidiDeviceForSource(int src) {
    for (WindowsMidiDevice wmd in _connectedDevices.values) {
      if (wmd.containsMidiIn(src)) {
        return wmd;
      }
    }
    return null;
  }
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


NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)> _cb = NativeCallable<MidiInProc>.listener(_onMidiData);

void _onMidiData(
    int hMidiIn, int wMsg, int dwInstance, int dwParam1, int dwParam2) {

  print('midi data $hMidiIn, $wMsg, $dwInstance, $dwParam1, $dwParam2');

  var dev = FlutterMidiCommandWindows().findMidiDeviceForSource(hMidiIn);
  print("data to ${dev?.name}");

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
      var data = pMidiHdr.ref.lpData
          .cast<Uint8>()
          .asTypedList(pMidiHdr.ref.dwBytesRecorded);
      dev?.handleSysexData(data);
      break;
    case MIM_MOREDATA:
      print("more data");
      break;
    case MIM_ERROR:
      print("Error");
      break;
    case MIM_LONGERROR:
      print("Long error");
      break;
  }
}

class WindowsMidiDevice extends MidiDevice {
  Map<int, MIDIINCAPS> _ins = {};
  Map<int, MIDIOUTCAPS> _outs = {};

  StreamController<MidiPacket> _rxStreamCtrl;
  StreamController<String> _setupStreamController;

  final hMidiInDevicePtr = calloc<HMIDIIN>();
  final hMidiOutDevicePtr = calloc<IntPtr>();

  int callbackAddress;

  Pointer<MIDIHDR> _midiInHeader = nullptr;
  Pointer<BYTE> _midiInBuffer = nullptr;

  WindowsMidiDevice(String name, this._rxStreamCtrl,
      this._setupStreamController, this.callbackAddress)
      : super(name, name, 'native', false);


  bool connect() {
    // Open input
    var mIn = _ins.entries.firstOrNull;
    if (mIn != null) {
      var id = mIn.key;
      int result = midiInOpen(
          hMidiInDevicePtr, id, callbackAddress, 0, CALLBACK_FUNCTION);
      if (result != 0) {
        print("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        // Setup buffer
        _midiInBuffer = calloc<BYTE>(1024);
        _midiInHeader = calloc<MIDIHDR>();
        _midiInHeader.ref.lpData = _midiInBuffer as LPSTR;
        _midiInHeader.ref.dwBufferLength = 1024;
        _midiInHeader.ref.dwFlags = 0;

        result = midiInPrepareHeader(
            hMidiInDevicePtr.value, _midiInHeader, sizeOf<MIDIHDR>());
        if (result != 0) {
          print("HDR PREP ERROR: ${midiErrorMessage(result)}");
          return false;
        }

        result = midiInAddBuffer(
            hMidiInDevicePtr.value, _midiInHeader, sizeOf<MIDIHDR>());
        if (result != 0) {
          print("HDR ADD ERROR: ${midiErrorMessage(result)}");
          return false;
        }

        result = midiInStart(hMidiInDevicePtr.value);
        if (result != 0) {
          print("START ERROR: ${midiErrorMessage(result)}");
          return false;
        }
      }
    }

    // Open output
    var mOut = _outs.entries.firstOrNull;
    if (mOut != null) {
      var id = mOut.key;
      int result = midiOutOpen(hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        print("OUT OPEN ERROR: result");
        return false;
      }
    }
    connected = true;
    _setupStreamController.add("deviceConnected");
    return true;
  }

  bool disconnect() {

    int result;
    if (_ins.length > 0) {
      result = midiInReset(hMidiInDevicePtr.value);
      if (result != 0) {
        print("RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInUnprepareHeader(
          hMidiInDevicePtr.value, _midiInHeader, sizeOf<MIDIHDR>());
      if (result != 0) {
        print("UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInStop(hMidiInDevicePtr.value);
      if (result != 0) {
        print("STOP ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInClose(hMidiInDevicePtr.value);
      if (result != 0) {
        print("CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }

      free(hMidiInDevicePtr);
    }

    if (_outs.length > 0) {
      result = midiOutClose(hMidiOutDevicePtr.value);
      if (result != 0) {
        print("OUT CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      free(hMidiOutDevicePtr);
    }

    free(_midiInBuffer);
    free(_midiInHeader);

    connected = false;
    return true;
  }

  addInput(int id, MIDIINCAPS input) {
    _ins[id] = input;
    inputPorts.add(MidiPort(input.wPid, MidiPortType.IN));
  }

  addOutput(int id, MIDIOUTCAPS output) {
    _outs[id] = output;
    outputPorts.add(MidiPort(output.wPid, MidiPortType.OUT));
  }

  containsMidiIn(int input) => hMidiInDevicePtr.value == input;

  _resetHeader() {
    midiInAddBuffer(hMidiInDevicePtr.value, _midiInHeader, sizeOf<MIDIHDR>());
  }

  handleData(Uint8List data, int timestamp) {
    //print('handle data $data');
    _rxStreamCtrl.add(MidiPacket(data, timestamp, this));
  }

  handleSysexData(Uint8List data) {
    //print('handle SysEX: $data');
    _rxStreamCtrl.add(MidiPacket(data, 0, this));
    _resetHeader();
  }

  send(Uint8List data) {
    final dList = Uint8List(4);
    dList.setAll(0, data);
    final d = dList.buffer.asByteData().getUint32(0, Endian.little);
    midiOutShortMsg(hMidiOutDevicePtr.value, d);
  }
}


// This API function is missing from win32
final _winmm = DynamicLibrary.open('winmm.dll');

int midiInAddBuffer(int hmi, Pointer<MIDIHDR> pmh, int cbmh) =>
    _midiInAddBuffer(hmi, pmh, cbmh);

final _midiInAddBuffer = _winmm.lookupFunction<
    Uint32 Function(IntPtr hmi, Pointer<MIDIHDR> pmh, Uint32 cbmh),
    int Function(int hmi, Pointer<MIDIHDR> pmh, int cbmh)>('midiInAddBuffer');
