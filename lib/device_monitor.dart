import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

late SendPort _sender;

var _windowId;

class DeviceMonitor {
  final _receiver = ReceivePort();

  Stream<_Message> get messages => _receiver.cast<_Message>();

  late Isolate _iso;

  void runMessagesIsolate() async {
    _iso = await Isolate.spawn(_entryPoint, _receiver.sendPort);
  }

  void destroy() {
    UnregisterDeviceNotification(_windowId);
    _receiver.close();
    _iso.kill();
  }
}

void _entryPoint(SendPort sender) {
  _sender = sender;

  final hInstance = GetModuleHandle(nullptr);
  const style = CS_HREDRAW | CS_VREDRAW;
  final lpfnWndProc =
      Pointer.fromFunction<LRESULT Function(HWND, UINT, WPARAM, LPARAM)>(
          _wndProc, 0);
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

    _windowId = CreateWindow(
        lpszClassName,
        "Message-Only FMCWin".toNativeUtf16(),
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        NULL,
        NULL,
        nullptr);

    GetMessage(msg, NULL, WM_QUIT, WM_QUIT);
  } catch (e) {
    print("ERROR $e");
  } finally {
    free(windowNamePointer);
    free(lpszClassName);
    free(lpWndClass);
    free(msg);
  }
}

int _wndProc(int hWnd, int uMsg, int wParam, int lParam) {
  if (uMsg == WM_CREATE) {
    // Message window created, register for notifications
    final notificationFilter = calloc<DEV_BROADCAST_DEVICEINTERFACE_W>()
      ..ref.dbcc_size = sizeOf<DEV_BROADCAST_DEVICEINTERFACE_W>()
      ..ref.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE
      ..ref.dbcc_classguid.setGUID(
          GUID_DEVINTERFACE_USB_DEVICE); //  setGUID("36FC9E60-C465-11CF-8056-444553540000");=

    try {
      final deviceNotifyPointer = RegisterDeviceNotification(
        hWnd,
        notificationFilter,
        DEVICE_NOTIFY_ALL_INTERFACE_CLASSES,
      );
      if (deviceNotifyPointer == NULL) {
        final statusCode = GetLastError();
        print("failed to register for device notifications: ${statusCode}");
        throw Exception(statusCode);
      } else {
        print("Successfully registered for device notifications");
      }
    } catch (e) {
      print("Device Notification Registration Error: $e");
    } finally {
      calloc.free(notificationFilter);
    }
  }

  if (uMsg == WM_DEVICECHANGE) {
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

  return DefWindowProc(hWnd, uMsg, wParam, lParam);
}

String convertUint16ArrayToString(Pointer<Uint16> arrayPointer) {
  int length = 0;
  while (arrayPointer.elementAt(length).value != 0) {
    length++;
  }
  print("String length $length");

  List<int> codeUnits = arrayPointer.asTypedList(length);
  print("Code units $codeUnits");
  String result = String.fromCharCodes(codeUnits);
  return result;
}

class _Message {
  final String event;
  final String? info;

  const _Message(this.event, {this.info = null});
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

late final UnregisterDeviceNotification = _winuser
    .lookup<NativeFunction<BOOL Function(PVOID)>>(
        'UnregisterDeviceNotificationW')
    .asFunction<int Function(PVOID)>();

int RegisterDeviceNotification(
        int hRecipient,
        Pointer<DEV_BROADCAST_DEVICEINTERFACE_W> notificationFilter,
        int flags) =>
    _RegisterDeviceNotification(hRecipient, notificationFilter.address, flags);

final _RegisterDeviceNotification = _winuser.lookupFunction<
    IntPtr Function(IntPtr hwnd, IntPtr filter, Uint32 flags),
    int Function(
        int hwnd, int filter, int flags)>('RegisterDeviceNotificationW');
