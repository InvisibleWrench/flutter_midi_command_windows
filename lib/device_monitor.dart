import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

late SendPort _sender;

class DeviceMonitor {
  factory DeviceMonitor() {
    _instance ??= DeviceMonitor._();
    return _instance!;
  }

  static DeviceMonitor? _instance;

  DeviceMonitor._() {
    _runMessagesIsolate();
  }

  final _receiver = ReceivePort();

  Stream<_Message> get messages => _receiver.cast<_Message>();

  void _runMessagesIsolate() async {
    Isolate.spawn(_device_monitor, _receiver.sendPort);
  }

  void destroy() {
    _receiver.close();
  }
}

void _device_monitor(SendPort sender) {
  _sender = sender;

  bool run = true;

  final hInstance = GetModuleHandle(nullptr);
  const style = WNDCLASS_STYLES.CS_HREDRAW | WNDCLASS_STYLES.CS_VREDRAW;
  final lpfnWndProc = Pointer.fromFunction<LRESULT Function(HWND, UINT, WPARAM, LPARAM)>(_wndProc, 0);
  final lpszClassName = 'STATIC'.toNativeUtf16();
  final lpWndClass = calloc<WNDCLASS>()
    ..ref.hInstance = hInstance
    ..ref.style = style
    ..ref.lpfnWndProc = lpfnWndProc
    ..ref.lpszClassName = lpszClassName;
  final windowNamePointer = 'messages window'.toNativeUtf16();
  final msg = calloc<MSG>();

  try {
    final registered = RegisterClass(lpWndClass);
    if (registered == 0) {
      final statusCode = GetLastError();
      print("Failed to register class: ${statusCode}");
      throw Exception(statusCode);
    }

    var _windowId = CreateWindow(lpszClassName, "Message-Only FMCWin".toNativeUtf16(), 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, NULL, nullptr);

    UpdateWindow(_windowId);

    int bRet = 0;

    while (run) {
      // Use PeekMessage instead of GetMessage
      bRet = PeekMessage(msg, NULL, 0, 0, PEEK_MESSAGE_REMOVE_TYPE.PM_REMOVE);

      // Check if a message is available
      if (bRet != 0) {
        // Check for a quit message
        print(msg.ref.message);
        if (msg.ref.message == WM_QUIT) {
          break;
        }

        TranslateMessage(msg);
        DispatchMessage(msg);
      } else {
        // Perform other tasks here when there are no messages
        // For example, update game logic, perform background processing, etc.
      }
    }

  } catch (e) {
    print("ERROR $e");
  } finally {
    free(windowNamePointer);
    free(lpszClassName);
    free(lpWndClass);
    free(msg);
  }
}

int _deviceNotifyPointer = 0;

int _wndProc(int hWnd, int uMsg, int wParam, int lParam) {
  switch (uMsg) {
    case WM_CLOSE:
      if (_deviceNotifyPointer != 0) {
        UnregisterDeviceNotification(_deviceNotifyPointer);
        _deviceNotifyPointer = NULL;
      }

      DestroyWindow(hWnd);
      break;

    case WM_DESTROY:
      PostQuitMessage(0);
      break;

    case WM_CREATE:
      {
        // Message window created, register for notifications
        final notificationFilter = calloc<DEV_BROADCAST_DEVICEINTERFACE_W>()
          ..ref.dbcc_size = sizeOf<DEV_BROADCAST_DEVICEINTERFACE_W>()
          ..ref.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE
          ..ref.dbcc_classguid.setGUID(GUID_DEVINTERFACE_USB_DEVICE); //  setGUID("36FC9E60-C465-11CF-8056-444553540000");=

        try {
          _deviceNotifyPointer = RegisterDeviceNotification(
            hWnd,
            notificationFilter,
            DEVICE_NOTIFY_ALL_INTERFACE_CLASSES,
          );
          if (_deviceNotifyPointer == NULL) {
            final statusCode = GetLastError();
            print("failed to register for device notifications: ${statusCode}");
            throw Exception(statusCode);
          }
        } catch (e) {
          print("Device Notification Registration Error: $e");
        } finally {
          calloc.free(notificationFilter);
        }
      }
      break;

    case WM_DEVICECHANGE:
      {
        if (wParam == DBT_DEVICEARRIVAL) {
          //print("device added");
          //DEV_BROADCAST_HDR hdr = Pointer<DEV_BROADCAST_HDR>.fromAddress(lParam).ref;
          //print("HDR type:${hdr.dbcc_devicetype}");
          //if (hdr.dbcc_devicetype == 5) {
          //DEV_BROADCAST_DEVICEINTERFACE_W device =
          //    Pointer<DEV_BROADCAST_DEVICEINTERFACE_W>.fromAddress(lParam).ref;
          //var deviceName = convertUint16ArrayToString(device.dbcc_name);
          //print("device name $deviceName");
          _sender.send(_Message("deviceAppeared"));
          //}
        } else if (wParam == DBT_DEVICEREMOVECOMPLETE) {
          _sender.send(_Message("deviceDisappeared"));
        }
      }
      break;
  }

  return DefWindowProc(hWnd, uMsg, wParam, lParam);
}

String convertUint16ArrayToString(Pointer<Uint16> arrayPointer) {
  int length = 0;
  while (arrayPointer.elementAt(length).value != 0) {
    length++;
  }

  List<int> codeUnits = arrayPointer.asTypedList(length);
  String result = String.fromCharCodes(codeUnits);
  return result;
}

class _Message {
  final String event;
  String? info;

  _Message(this.event);
}

const DBT_DEVTYP_DEVICEINTERFACE = 0x00000005;

base class DEV_BROADCAST_DEVICEINTERFACE_W extends Struct {
  @DWORD()
  external int dbcc_size;
  @DWORD()
  external int dbcc_devicetype;
  @DWORD()
  external int dbcc_reserved;
  external GUID dbcc_classguid;

  external Pointer<Uint16> dbcc_name;
}

base class DEV_BROADCAST_HDR extends Struct {
  @DWORD()
  external int dbcc_size;
  @DWORD()
  external int dbcc_devicetype;
  @DWORD()
  external int dbcc_reserved;
}

const DEVICE_NOTIFY_ALL_INTERFACE_CLASSES = 4;

final _winuser = DynamicLibrary.open('user32.dll');

int UnregisterDeviceNotification(int handle) => _UnregisterDeviceNotification(handle);

final _UnregisterDeviceNotification = _winuser.lookupFunction<BOOLEAN Function(IntPtr handle), int Function(int handle)>('UnregisterDeviceNotification');

int RegisterDeviceNotification(int hRecipient, Pointer<DEV_BROADCAST_DEVICEINTERFACE_W> notificationFilter, int flags) =>
    _RegisterDeviceNotification(hRecipient, notificationFilter.address, flags);

final _RegisterDeviceNotification = _winuser
    .lookupFunction<IntPtr Function(IntPtr hwnd, IntPtr filter, Uint32 flags), int Function(int hwnd, int filter, int flags)>('RegisterDeviceNotificationW');
