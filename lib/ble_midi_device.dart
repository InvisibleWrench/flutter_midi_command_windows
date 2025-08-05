import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:universal_ble/universal_ble.dart';
import 'dart:collection';

enum DeviceState { None, Interrogating, Available, Irrelevant }

enum ConnectionState { Disconnected, Connecting, Connected }

const MIDI_SERVICE_ID = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700";
const MIDI_CHARACTERISTIC_ID = "7772E5DB-3868-4112-A1A9-F2669D106BF3";

// BLE MIDI parsing
enum BLE_HANDLER_STATE { HEADER, TIMESTAMP, STATUS, STATUS_RUNNING, PARAMS, SYSTEM_RT, SYSEX, SYSEX_END, SYSEX_INT }

class BLEMidiDevice extends MidiDevice {
  String deviceId;
  String name;
  DeviceState devState = DeviceState.None;

  StreamController<MidiPacket> _rxStreamCtrl;

  set connectionState(BleConnectionState state) {
    UniversalBle.requestMtu(deviceId, 247);

    if (devState.index < DeviceState.Interrogating.index) {
      _discoverServices();
    }
    connected = (state == BleConnectionState.connected);
  }

  set pairingState(bool value) {
    if (value == true) {
      _startNotify();
    }
  }

  BleService? _midiService;
  BleCharacteristic? _midiCharacteristic;

  BLEMidiDevice(this.deviceId, this.name, this._rxStreamCtrl) : super(deviceId, name, 'BLE', false) {}

  connect() {
    UniversalBle.connect(deviceId);
  }

  disconnect() {
    UniversalBle.setNotifiable(deviceId, _midiService!.uuid, _midiCharacteristic!.uuid, BleInputProperty.disabled);
    UniversalBle.disconnect(deviceId);
  }

  send(Uint8List bytes) async {
    if (_midiService == null) return;
    if (_midiCharacteristic == null) return;

    var packetSize = 20;

    List<int> dataBytes = List.from(bytes);

    if (bytes.first == 0xF0 && bytes.last == 0xF7) {
      //  this is a sysex message, handle carefully
      if (bytes.length > packetSize - 3) {
        // Split into multiple messages of 20 bytes total

        // First packet
        List<int> packet = dataBytes.take(packetSize - 2).toList();

        // Insert header(and empty timstamp high) and timestamp low in front Sysex Start
        packet.insert(0, 0x80);
        packet.insert(0, 0x80);

        _sendBytes(packet);

        dataBytes = dataBytes.skip(packetSize - 2).toList();

        // More packets
        while (dataBytes.length > 0) {
          int pickCount = min(dataBytes.length, packetSize - 1);
          packet = dataBytes.getRange(0, pickCount).toList(); // Pick bytes for packet
          // Insert header
          packet.insert(0, 0x80);

          if (packet.length < packetSize) {
            // Last packet
            // Timestamp before Sysex End byte
            packet.insert(packet.length - 1, 0x80);
          }

          // Wait for buffer to clear
          _sendBytes(packet);

          if (dataBytes.length > packetSize - 2) {
            dataBytes = dataBytes.skip(pickCount).toList(); // Advance buffer
          } else {
            return;
          }
        }
      } else {
        // Insert timestamp low in front of Sysex End-byte
        dataBytes.insert(bytes.length - 1, 0x80);

        // Insert header(and empty timstamp high) and timestamp low in front of BLE Midi message
        dataBytes.insert(0, 0x80);
        dataBytes.insert(0, 0x80);

        _sendBytes(dataBytes);
      }
      return;
    }

    // In bluetooth MIDI we need to send each midi command separately
    List<int> currentBuffer = [];
    for (int i = 0; i < dataBytes.length; i++) {
      int byte = dataBytes[i];

      // Insert header(and empty timestamp high) and timestamp
      // low in front of BLE Midi message
      if ((byte & 0x80) != 0) {
        currentBuffer.insert(0, 0x80);
        currentBuffer.insert(0, 0x80);
      }
      currentBuffer.add(byte);

      // Send each MIDI command separately
      bool endReached = i == (dataBytes.length - 1);
      bool isCompleteCommand = endReached || (dataBytes[i + 1] & 0x80) != 0;

      if (isCompleteCommand) {
        _sendBytes(currentBuffer);
        currentBuffer = [];
      }
    }
  }

  _sendBytes(List<int> bytes) async {
    try {
      await UniversalBle.write(
        deviceId,
        _midiService!.uuid,
        _midiCharacteristic!.uuid,
        Uint8List.fromList(bytes),
        withoutResponse: true,
      );
    } catch (e) {
      print('WriteError  $e');
    }
  }

  handleData(Uint8List data) {
    _parseBLEPacket(data);
  }

  _discoverServices() async {
    devState = DeviceState.Interrogating;

    var services = await UniversalBle.discoverServices(deviceId);
    _midiService = services.where((service) => service.uuid.toUpperCase() == MIDI_SERVICE_ID).firstOrNull;
    if (_midiService != null) {
      _midiCharacteristic = _midiService!.characteristics.where((characteristic) => characteristic.uuid.toUpperCase() == MIDI_CHARACTERISTIC_ID).firstOrNull;
      if (_midiCharacteristic != null) {
        var isPaired = await UniversalBle.isPaired(deviceId);

        if (isPaired ?? false) {
          _startNotify();
        } else {
          try {
            await UniversalBle.pair(deviceId);
          } catch (e) {
            print(e);
          }
        }
      } else {
        devState = DeviceState.Irrelevant;
      }
    } else {
      devState = DeviceState.Irrelevant;
    }
  }

  _startNotify() {
    try {
      UniversalBle.setNotifiable(deviceId, _midiService!.uuid, _midiCharacteristic!.uuid, BleInputProperty.notification);
    } catch (e) {
      print(e);
    }
  }

  _createMessageEvent(List<int> bytes, int timestamp) {
    _rxStreamCtrl.add(MidiPacket(Uint8List.fromList(bytes), timestamp, this));
  }

  var bleHandlerState = BLE_HANDLER_STATE.HEADER;
  List<int> sysExBuffer = [];
  int timestamp = 0;
  List<int> bleMidiBuffer = [];
  int bleMidiPacketLength = 0;
  bool bleSysExHasFinished = true;

  _parseBLEPacket(Uint8List packet) {
    if (packet.length > 1) {
      // parse BLE message
      bleHandlerState = BLE_HANDLER_STATE.HEADER;

      var header = packet[0];
      int statusByte = 0;

      for (int i = 1; i < packet.length; i++) {
        int midiByte = packet[i];

        if ((((midiByte & 0x80) == 0x80) && (bleHandlerState != BLE_HANDLER_STATE.TIMESTAMP)) && (bleHandlerState != BLE_HANDLER_STATE.SYSEX_INT)) {
          if (!bleSysExHasFinished) {
            bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT;
          } else {
            bleHandlerState = BLE_HANDLER_STATE.TIMESTAMP;
          }
        } else {
          // State handling
          switch (bleHandlerState) {
            case BLE_HANDLER_STATE.HEADER:
              if (!bleSysExHasFinished) {
                if ((midiByte & 0x80) == 0x80) {
                  // System messages can interrupt ongoing sysex
                  bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT;
                } else {
                  // Sysex continue
                  bleHandlerState = BLE_HANDLER_STATE.SYSEX;
                }
              }
              break;

            case BLE_HANDLER_STATE.TIMESTAMP:
              if ((midiByte & 0xFF) == 0xF0) {
                // Sysex start
                bleSysExHasFinished = false;
                sysExBuffer.clear();
                bleHandlerState = BLE_HANDLER_STATE.SYSEX;
              } else if ((midiByte & 0x80) == 0x80) {
                // Status/System start
                bleHandlerState = BLE_HANDLER_STATE.STATUS;
              } else {
                bleHandlerState = BLE_HANDLER_STATE.STATUS_RUNNING;
              }
              break;

            case BLE_HANDLER_STATE.STATUS:
              bleHandlerState = BLE_HANDLER_STATE.PARAMS;
              break;

            case BLE_HANDLER_STATE.STATUS_RUNNING:
              bleHandlerState = BLE_HANDLER_STATE.PARAMS;
              break;

            case BLE_HANDLER_STATE.PARAMS: // After params can come TSlow or more params
              break;

            case BLE_HANDLER_STATE.SYSEX:
              break;

            case BLE_HANDLER_STATE.SYSEX_INT:
              if ((midiByte & 0xFF) == 0xF7) {
                // Sysex end
                bleSysExHasFinished = true;
                bleHandlerState = BLE_HANDLER_STATE.SYSEX_END;
              } else {
                bleHandlerState = BLE_HANDLER_STATE.SYSTEM_RT;
              }
              break;

            case BLE_HANDLER_STATE.SYSTEM_RT:
              if (!bleSysExHasFinished) {
                // Continue incomplete Sysex
                bleHandlerState = BLE_HANDLER_STATE.SYSEX;
              }
              break;

            default:
              print("Unhandled state $bleHandlerState");
              break;
          }
        }

        // Data handling
        switch (bleHandlerState) {
          case BLE_HANDLER_STATE.TIMESTAMP:
            int tsHigh = header & 0x3f;
            int tsLow = midiByte & 0x7f;
            timestamp = tsHigh << 7 | tsLow;
            break;

          case BLE_HANDLER_STATE.STATUS:
            bleMidiPacketLength = _lengthOfMessageType(midiByte);
            bleMidiBuffer.clear();
            bleMidiBuffer.add(midiByte);

            if (bleMidiPacketLength == 1) {
              _createMessageEvent(bleMidiBuffer, timestamp);
            } else {
              statusByte = midiByte;
            }
            break;

          case BLE_HANDLER_STATE.STATUS_RUNNING:
            bleMidiPacketLength = _lengthOfMessageType(statusByte);
            bleMidiBuffer.clear();
            bleMidiBuffer.add(statusByte);
            bleMidiBuffer.add(midiByte);

            if (bleMidiPacketLength == 2) {
              _createMessageEvent(bleMidiBuffer, timestamp);
            }
            break;

          case BLE_HANDLER_STATE.PARAMS:
            bleMidiBuffer.add(midiByte);

            if (bleMidiPacketLength == bleMidiBuffer.length) {
              _createMessageEvent(bleMidiBuffer, timestamp);
              bleMidiBuffer.removeRange(1, bleMidiBuffer.length); // Remove all but status, which might be used for running msgs
            }
            break;

          case BLE_HANDLER_STATE.SYSTEM_RT:
            _createMessageEvent([midiByte], timestamp);
            break;

          case BLE_HANDLER_STATE.SYSEX:
            sysExBuffer.add(midiByte);
            break;

          case BLE_HANDLER_STATE.SYSEX_INT:
            break;

          case BLE_HANDLER_STATE.SYSEX_END:
            sysExBuffer.add(midiByte);
            _createMessageEvent(sysExBuffer, 0);
            break;

          default:
            print("Unhandled state (data) $bleHandlerState)");
            break;
        }
      }
    }
  }

  int _lengthOfMessageType(int type) {
    var midiType = type & 0xF0;

    switch (type) {
      case 0xF6:
      case 0xF8:
      case 0xFA:
      case 0xFB:
      case 0xFC:
      case 0xFF:
      case 0xFE:
        return 1;
      case 0xF1:
      case 0xF3:
        return 2;
      case 0xF2:
        return 3;
      default:
        break;
    }

    switch (midiType) {
      case 0xC0:
      case 0xD0:
        return 2;
      case 0x80:
      case 0x90:
      case 0xA0:
      case 0xB0:
      case 0xE0:
        return 3;
      default:
        break;
    }
    return 0;
  }
}
