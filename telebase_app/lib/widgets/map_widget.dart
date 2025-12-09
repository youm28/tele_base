import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:telebase_app/model/map_transform_state.dart';
import 'package:telebase_app/model/pin_model.dart';
import 'package:telebase_app/utils/helpers/map_helper.dart';
import 'package:telebase_app/widgets/map_image.dart';
import 'package:telebase_app/widgets/robot_widget.dart';
import 'package:kachaka_api/kachaka_api.dart';
import 'package:telebase_app/widgets/map_arrow_painter.dart';

class MapWidget extends HookConsumerWidget {
  final Map_ mapInfo;
  final List<PinModel> pins;
  final ValueNotifier<MapTransformState> mapTransformState;
  final List<Pose>? previewPath;

  const MapWidget({
    super.key,
    required this.mapInfo,
    required this.pins,
    required this.mapTransformState,
    this.previewPath,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(builder: (context, constraints) {
      // ★変更: 回転させないため、縦横の制約を入れ替える処理(swappedConstraints)を削除し、
      // そのままの constraints を使用します。

      return HookBuilder(builder: (context) {
        final transformationController = useTransformationController();
        final mapLayout = useMemoized(
            () => MapHelper.calcMapSize(
                  mapInfo: mapInfo,
                  constraints:
                      constraints, // ★変更: swappedConstraints -> constraints
                ),
            [mapInfo, constraints]); // ★変更: swappedConstraints -> constraints

        useEffect(() {
          // ★変更: swappedConstraints -> constraints
          final scaleX = constraints.maxWidth / mapLayout.mapWidth;
          final scaleY = constraints.maxHeight / mapLayout.mapHeight;
          final initialScale = math.min(scaleX, scaleY);

          transformationController.value = Matrix4.identity()
            ..scale(initialScale);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mapTransformState.value.scale == 1.0) {
              mapTransformState.value =
                  mapTransformState.value.copyWith(scale: initialScale);
            }
          });

          return null;
        }, [mapLayout]);

        // プレビューパスを画面座標(Offset)に変換
        List<Offset> arrowOffsets = [];
        if (previewPath != null) {
          arrowOffsets = previewPath!.map((pose) {
            final loc = MapHelper.pinWidgetToMapLocation(
              mapInfo: mapInfo,
              pose: pose,
              pinCenterFormLeft: 0,
              pinCenterFromBottom: 0,
              layoutInfo: mapLayout,
            );
            // bottom基準をtop基準に変換
            return Offset(loc[0], mapLayout.mapHeight - loc[1]);
          }).toList();
        }

        // ★変更: RotatedBox を削除しました
        return InteractiveViewer(
          transformationController: transformationController,
          maxScale: double.infinity,
          minScale: 0.2,
          onInteractionUpdate: (details) {
            final scale = transformationController.value.getMaxScaleOnAxis();
            mapTransformState.value =
                mapTransformState.value.copyWith(scale: scale);
          },
          scaleEnabled: true,
          panEnabled: true,
          child: SizedBox(
            width: mapLayout.mapWidth,
            height: mapLayout.mapHeight,
            child: Stack(
              children: [
                MapImage(
                  mapInfo: mapInfo,
                  width: mapLayout.mapWidth,
                  height: mapLayout.mapHeight,
                ),

                // 経路プレビュー描画
                if (arrowOffsets.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: MapArrowPainter(
                        points: arrowOffsets,
                        color: Colors.orangeAccent.withOpacity(0.8),
                      ),
                    ),
                  ),

                ...pins.map(
                  (e) {
                    final scaleFactor = e.shouldScale
                        ? 1.0 /
                            (mapTransformState.value.scale == 0
                                ? 0.01
                                : mapTransformState.value.scale)
                        : 1.0;
                    final loc = MapHelper.pinWidgetToMapLocation(
                      mapInfo: mapInfo,
                      pose: e.pose,
                      pinCenterFormLeft: e.pinCenterOffset.dx,
                      pinCenterFromBottom: e.pinCenterOffset.dy,
                      layoutInfo: mapLayout,
                    );
                    return Positioned(
                      left: loc[0],
                      bottom: loc[1],
                      child: Transform.scale(
                        alignment: Alignment.bottomLeft,
                        scale: scaleFactor,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => e.onTap?.call(),
                          child: e.child,
                        ),
                      ),
                    );
                  },
                ),
                RobotWidget(
                  mapInfo: mapInfo,
                  layoutInfo: mapLayout,
                ),
              ],
            ),
          ),
        );
      });
    });
  }
}
