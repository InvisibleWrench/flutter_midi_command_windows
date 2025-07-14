import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';

import 'flutter_midi_command_windows.dart';

class WindowsMidiDevice extends MidiDevice {
  Map<int, MIDIINCAPS> _ins = {};
  Map<int, MIDIOUTCAPS> _outs = {};

  StreamController<MidiPacket> _rxStreamCtrl;
  StreamController<String> _setupStreamController;

  final hMidiInDevicePtr = malloc<HMIDIIN>();
  final hMidiOutDevicePtr = malloc<IntPtr>();

  int callbackAddress;

  final _bufferSize = 4096;

  Pointer<MIDIHDR> _midiInHeader = nullptr;
  Pointer<BYTE> _midiInBuffer = nullptr;

  Pointer<MIDIHDR> _midiInHeader2 = nullptr;
  Pointer<BYTE> _midiInBuffer2 = nullptr;

  Pointer<MIDIHDR> _midiOutHeader = nullptr;
  Pointer<BYTE> _midiOutBuffer = nullptr;

  WindowsMidiDevice(String id, String name, this._rxStreamCtrl,
      this._setupStreamController, this.callbackAddress)
      : super(id, name, 'native', false);

  /// Connect to the device, ie. open input and output ports
  /// NOTE: Currently only the first input/output port is considered
  bool connect() {
    // Open input

    var mIn = _ins.entries.firstOrNull;
    if (mIn != null) {
      var id = mIn.key;
      int result = midiInOpen(hMidiInDevicePtr, id, callbackAddress, 0, CALLBACK_FUNCTION);
      if (result != 0) {
        print("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        // Setup buffer
        _midiInBuffer = malloc<BYTE>(_bufferSize);
        _midiInHeader = malloc<MIDIHDR>();
        _midiInHeader.ref.lpData = _midiInBuffer as LPSTR;
        _midiInHeader.ref.dwBufferLength = _bufferSize;
        _midiInHeader.ref.dwFlags = 0;
        _midiInHeader.ref.dwBytesRecorded = 0;

        // Setup buffer 2
        _midiInBuffer2 = malloc<BYTE>(_bufferSize);
        _midiInHeader2 = malloc<MIDIHDR>();
        _midiInHeader2.ref.lpData = _midiInBuffer2 as LPSTR;
        _midiInHeader2.ref.dwBufferLength = _bufferSize;
        _midiInHeader2.ref.dwFlags = 0;
        _midiInHeader2.ref.dwBytesRecorded = 0;

        result = midiInPrepareHeader(
            hMidiInDevicePtr.value, _midiInHeader, sizeOf<MIDIHDR>());
        if (result != 0) {
          print("HDR PREP ERROR: ${midiErrorMessage(result)}");
          return false;
        }

        result = midiInPrepareHeader(
            hMidiInDevicePtr.value, _midiInHeader2, sizeOf<MIDIHDR>());
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

        result = midiInAddBuffer(
            hMidiInDevicePtr.value, _midiInHeader2, sizeOf<MIDIHDR>());
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

      int result = midiOutOpen(
          hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        print("OUT OPEN ERROR: result");
        return false;
      }

      _midiOutBuffer = malloc<BYTE>(_bufferSize);
      _midiOutHeader = malloc<MIDIHDR>();
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
      result = midiInUnprepareHeader(
          hMidiInDevicePtr.value, _midiInHeader2, sizeOf<MIDIHDR>());
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
    free(_midiInBuffer2);
    free(_midiInHeader2);
    free(_midiOutBuffer);
    free(_midiOutHeader);

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

  _resetHeader(Pointer<MIDIHDR> midiHdrPointer) {
    midiInAddBuffer(hMidiInDevicePtr.value, midiHdrPointer, sizeOf<MIDIHDR>());
  }

  handleData(Uint8List data, int timestamp) {
    // print('handle data $data');
    _rxStreamCtrl.add(MidiPacket(data, timestamp, this));
  }

  handleSysexData(Uint8List data, Pointer<MIDIHDR> midiHdrPointer) {
    // print('handle SysEX: $data');
    _rxStreamCtrl.add(MidiPacket(data, 0, this));
    _resetHeader(midiHdrPointer);
  }

  send(Uint8List data) async {
    // Set data in out buffer
    _midiOutBuffer.asTypedList(data.length).setAll(0, data);
    _midiOutHeader.ref.lpData = _midiOutBuffer as LPSTR;
    _midiOutHeader.ref.dwBytesRecorded =
        _midiOutHeader.ref.dwBufferLength = data.length;
    _midiOutHeader.ref.dwFlags = 0;

    int result = midiOutPrepareHeader(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("HDR OUT PREP ERROR: ${midiErrorMessage(result)}");
    }

    result = midiOutLongMsg(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("SEND ERROR($result): ${midiErrorMessage(result)}");
    }

    result = midiOutUnprepareHeader(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("OUT UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
    }
  }
}
