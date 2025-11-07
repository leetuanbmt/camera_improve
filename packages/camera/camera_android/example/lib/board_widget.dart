// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';

/// Blackboard overlay widget
///
/// Features:
/// - Draggable position
/// - Resizable
/// - Text labels
/// - Screenshot capture support
class BoardWidget extends StatefulWidget {
  const BoardWidget({
    super.key,
    required this.screenshotController,
    this.onPositionChanged,
    this.onSizeChanged,
    this.initialPosition,
    this.initialSize,
    this.opacity = 1.0,
  });

  final ScreenshotController screenshotController;
  final Function(Offset)? onPositionChanged;
  final Function(Size)? onSizeChanged;
  final Offset? initialPosition;
  final Size? initialSize;
  final double opacity;

  @override
  State<BoardWidget> createState() => _BoardWidgetState();
}

class _BoardWidgetState extends State<BoardWidget> {
  late Offset _position;
  late Size _size;

  // Board data
  final List<BoardLabel> _labels = [
    BoardLabel(text: '工事名', value: 'Sample Project', position: Offset(10, 10)),
    BoardLabel(text: '報告書名', value: 'Test Report', position: Offset(10, 40)),
    BoardLabel(text: '場所', value: 'Tokyo', position: Offset(10, 70)),
  ];

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition ?? const Offset(20, 100);
    _size = widget.initialSize ?? const Size(300, 200);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: Screenshot(
        controller: widget.screenshotController,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _position = Offset(
                _position.dx + details.delta.dx,
                _position.dy + details.delta.dy,
              );
            });
            widget.onPositionChanged?.call(_position);
          },
          child: Container(
            width: _size.width,
            height: _size.height,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(widget.opacity * 0.8),
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                // Background
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.grey.shade900.withOpacity(widget.opacity),
                        Colors.grey.shade800.withOpacity(widget.opacity),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),

                // Labels
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _labels.map((label) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: [
                            Text(
                              '${label.text}: ',
                              style: TextStyle(
                                color: Colors.white.withOpacity(widget.opacity),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              label.value,
                              style: TextStyle(
                                color: Colors.white.withOpacity(widget.opacity),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),

                // Drag indicator
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Icon(
                    Icons.drag_indicator,
                    color: Colors.white.withOpacity(widget.opacity * 0.5),
                    size: 20,
                  ),
                ),

                // Edit button
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    icon: Icon(
                      Icons.edit,
                      color: Colors.white.withOpacity(widget.opacity),
                      size: 20,
                    ),
                    onPressed: () {
                      // TODO: Open edit dialog
                      _showEditDialog();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showEditDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Board Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _labels.map((label) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: TextField(
                decoration: InputDecoration(
                  labelText: label.text,
                  border: const OutlineInputBorder(),
                ),
                controller: TextEditingController(text: label.value),
                onChanged: (value) {
                  setState(() {
                    label.value = value;
                  });
                },
              ),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Board label data model
class BoardLabel {
  BoardLabel({
    required this.text,
    required this.value,
    required this.position,
  });

  final String text;
  String value;
  final Offset position;
}
