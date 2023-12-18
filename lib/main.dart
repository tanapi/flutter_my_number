import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/platform_tags.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    // 縦向き固定
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) {
    runApp(const MyApp());
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'マイナンバー読み込み'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _message = '';
  final _pinController = TextEditingController();

  void _setMessage(String s) {
    setState(() {
      _message = s;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          children: [
            Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  children: [
                    const Text('PIN(4桁数字)：'),
                    SizedBox(
                      width: 100.0,
                      height: 64.0,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 4,
                        textAlign: TextAlign.center,
                        controller: _pinController,
                      ),
                    )
                  ],
                )),
            ElevatedButton(
              onPressed: () => onStart(),
              child: const Text('カード読み取り', style: TextStyle(fontSize: 24),),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 30, right: 15, bottom: 15, left: 15),
              child: Text(_message,
                  style: const TextStyle(fontSize: 20)),
            )
          ],
        ),
      ),
    );
  }

  // onStart
  Future onStart() async {
    if (_pinController.text.length != 4) {
      _setMessage('PINを入力してください');
      return;
    }

    // NFC通信を行う
    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      _setMessage('NFCが使えません');
      return;
    }
    _setMessage('カードをタッチしてください');
    try {
      await NfcManager.instance.startSession(
        alertMessage: "カードにタッチしてください",
        onDiscovered: (NfcTag tag) async {
          try {
            if (Platform.isIOS) {
              await onDiscoveredForIos(tag);
            }
            if (Platform.isAndroid) {
              await onDiscoveredForAndroid(tag);
            }
          } catch (e) {
            _setMessage('Error\n${e.toString()}');
            NfcManager.instance.stopSession(errorMessage: 'Error ${e.toString()}');
          }
          NfcManager.instance.stopSession();
        },
      );
    } catch (e) {
      _setMessage('Error\n${e.toString()}');
    }
  }

  // for iOS
  Future onDiscoveredForIos(NfcTag tag) async {
    final iso7816 = Iso7816.from(tag);
    if (iso7816 == null) {
      _setMessage('未対応のカードです');
      return;
    }

    String s = '';

    try {
      // SELECT FILE: 券面入力補助AP (DF)
      List<int> cmd = [0x00, 0xA4, 0x04, 0x0C, 0x0A, 0xD3, 0x92, 0x10, 0x00, 0x31, 0x00, 0x01, 0x01, 0x04, 0x08];
      var res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      // SELECT FILE: 券面入力補助用PIN (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x11];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      // VERIFY: 券面入力補助用PIN
      Uint8List pin = utf8.encode(_pinController.text);
      cmd = [0x00, 0x20, 0x00, 0x80, 0x04, ... pin];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord1 == 0x63) {
        var retry = res.statusWord2 - 0xC0;
        String msg = 'PINが違います(あと$retry回)';
        _setMessage(msg);
        return;
      }
      if (res.statusWord2 != 0x00) return;

      // SELECT FILE: マイナンバー (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x01];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      // READ BINARY: マイナンバー読み取り
      cmd = [0x00, 0xB0, 0x00, 0x00, 0x00];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      s = 'マイナンバー：';
      s += utf8.decode(res.payload.sublist(3, 15));

      // SELECT FILE: 基本4情報 (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x02];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      // READ BINARY: 基本4情報読み取り
      cmd = [0x00, 0xB0, 0x00, 0x00, 0x00];
      res = await iso7816.sendCommandRaw(Uint8List.fromList(cmd));
      if (res.statusWord2 != 0x00) return;

      s += '\n';
      s += getDerName(res.payload);
      s += '\n';
      s += getDerAddress(res.payload);
      s += '\n';
      s += getDerBirth(res.payload);
      s += '\n';
      s += getDerSex(res.payload);
    } catch (e) {
      s += 'Error:${e.toString()}';
    }
    _setMessage(s);
  }

  // for Android
  Future onDiscoveredForAndroid(NfcTag tag) async {
    final isoDep = IsoDep.from(tag);
    if (isoDep == null) {
      _setMessage('未対応のカードです');
      return;
    }

    String s = '';

    try {
      // SELECT FILE: 券面入力補助AP (DF)
      List<int> cmd = [0x00, 0xA4, 0x04, 0x0C, 0x0A, 0xD3, 0x92, 0x10, 0x00, 0x31, 0x00, 0x01, 0x01, 0x04, 0x08];
      Uint8List res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res.last != 0x00) return;

      // SELECT FILE: 券面入力補助用PIN (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x11];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res.last != 0x00) return;

      // VERIFY: 券面入力補助用PIN
      Uint8List pin = utf8.encode(_pinController.text);
      cmd = [0x00, 0x20, 0x00, 0x80, 0x04, ... pin];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res[0] == 0x63) {
        var retry = res.last - 0xC0;
        String msg = 'PINが違います(あと$retry回)';
        _setMessage(msg);
        return;
      }
      if (res.last != 0x00) return;

      // SELECT FILE: マイナンバー (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x01];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res.last != 0x00) return;

      // READ BINARY: マイナンバー読み取り
      cmd = [0x00, 0xB0, 0x00, 0x00, 0x00];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res.last != 0x00) return;

      s = 'マイナンバー：';
      s += utf8.decode(res.sublist(3, 15));

      // SELECT FILE: 基本4情報 (EF)
      cmd = [0x00, 0xA4, 0x02, 0x0C, 0x02, 0x00, 0x02];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res.last != 0x00) return;

      // READ BINARY: 基本4情報読み取り
      cmd = [0x00, 0xB0, 0x00, 0x00, 0x00];
      res = await isoDep.transceive(data: Uint8List.fromList(cmd));
      if (res[res.length - 1] != 0x00) return;

      s += '\n';
      s += getDerName(res);
      s += '\n';
      s += getDerAddress(res);
      s += '\n';
      s += getDerBirth(res);
      s += '\n';
      s += getDerSex(res);
    } catch (e) {
      s += 'Error:${e.toString()}';
    }
    _setMessage(s);
  }

  // 基本4情報から氏名取得
  String getDerName(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0xDF && data[i + 1] == 0x22) {
        String s = '氏名：';
        s += utf8.decode(data.sublist(i + 3, i + 3 + data[i + 2]));
        return s;
      }
    }
    return '';
  }

  // 基本4情報から住所取得
  String getDerAddress(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0xDF && data[i + 1] == 0x23) {
        String s = '住所：';
        s += utf8.decode(data.sublist(i + 3, i + 3 + data[i + 2]));
        return s;
      }
    }
    return '';
  }

  // 基本4情報から生年月日取得
  String getDerBirth(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0xDF && data[i + 1] == 0x24) {
        String s = '生年月日：';
        s += utf8.decode(data.sublist(i + 3, i + 3 + data[i + 2]));
        return s;
      }
    }
    return '';
  }

  // 基本4情報から性別取得
  String getDerSex(Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0xDF && data[i + 1] == 0x25) {
        switch (data[i + 3]) {
          case 0x31:
            return '性別：男性';
          case 0x32:
            return '性別：女性';
          default:
            return '性別：その他';
        }
      }
    }
    return '';
  }
}
