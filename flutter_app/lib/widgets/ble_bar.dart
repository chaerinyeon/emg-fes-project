import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants.dart';

class BleBar extends StatelessWidget {
  final String connState;
  final BluetoothDevice? device;
  final bool scanning;
  final VoidCallback onScanAndConnect;
  final VoidCallback onDisconnect;

  const BleBar({
    super.key,
    required this.connState,
    required this.device,
    required this.scanning,
    required this.onScanAndConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final isConn = connState == 'connected';
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white10,
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  isConn
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  size: 18,
                  color: isConn ? Colors.greenAccent : Colors.white60,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isConn
                        ? (device?.platformName.isNotEmpty == true
                              ? device!.platformName
                              : kDeviceName)
                        : 'Device: $kDeviceName  (UUID ${kServiceUuid.substring(0, 8)}…)',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: isConn ? onDisconnect : (scanning ? null : onScanAndConnect),
          child: Text(
            isConn
                ? 'Disconnect'
                : (scanning ? 'Scanning…' : 'Scan & Connect'),
          ),
        ),
      ],
    );
  }
}
