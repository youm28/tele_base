import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // キーボード操作用
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:telebase_app/model/map_transform_state.dart';
import 'package:telebase_app/model/pin_model.dart';
import 'package:telebase_app/service/server_communication_service.dart';
import 'package:telebase_app/service/servo_service.dart';
import 'package:telebase_app/stores/location/location_store.dart';
import 'package:telebase_app/stores/map/map_store.dart';
import 'package:telebase_app/stores/robot/robot_store.dart';
import 'package:kachaka_api/kachaka_api.dart';
import 'package:telebase_app/widgets/map_widget.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

class HomeScreen extends HookConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 初回ビルド時にServoサーバーへも接続
    useEffect(() {
      ref.read(servoServiceProvider).connect();
      return null;
    }, []);

    final robotStatus = ref.watch(robotStatusProvider);
    final cooperationMessage = ref.watch(cooperationMessageProvider);
    final userId = ref.watch(userIdProvider);
    final isRobotBusy = robotStatus == 'moving';

    final locations = ref
        .watch(locationStoreProvider.select((value) => value.locations ?? []));
    final mapInfo =
        ref.watch(mapStoreProvider.select((value) => value.mapInfo));
    final robotPose =
        ref.watch(robotStoreProvider.select((value) => value.pose));
    final mapTransformState = useState(MapTransformState.init());

    final currentLocation = ref.watch(currentLocationProvider);
    final isSystemReady = ref.watch(isSystemReadyProvider);
    final destinationSelector = ref.watch(destinationSelectorProvider);

    // ★ 追加: UIモードとルート情報の監視
    final uiMode = ref.watch(uiModeProvider);
    final routeOptions = ref.watch(routeOptionsProvider);
    final targetDestination = ref.watch(targetDestinationProvider);

    const allowedStartLocations = ['充電ドック', '1', '2', '3', '4', '5', '6'];
    final isAtValidStartLocation =
        allowedStartLocations.contains(currentLocation);

    // ★ キーボード入力ハンドラ (矢印キー・左右反転)
    void handleKeyEvent(KeyEvent event) {
      if (userId == null) return;
      if (event is! KeyDownEvent && event is! KeyUpEvent) return;
      final isPressed = event is KeyDownEvent;
      final servoService = ref.read(servoServiceProvider);

      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        servoService.handleKeyInput(
            axis: 'horizontal', isPositive: false, isPressed: isPressed);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        servoService.handleKeyInput(
            axis: 'horizontal', isPositive: true, isPressed: isPressed);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        servoService.handleKeyInput(
            axis: 'vertical', isPositive: true, isPressed: isPressed);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        servoService.handleKeyInput(
            axis: 'vertical', isPositive: false, isPressed: isPressed);
      }
    }

    void sendRequest(Location targetLocation) {
      if (robotPose == null) return;
      ref
          .read(serverCommunicationServiceProvider)
          .sendDestinationRequest(targetLocation, robotPose);
    }

    // 目的地リスト作成
    final availableDestinations = locations.where((l) {
      final allowedNames = ['1', '2', '3', '4', '5', '6'];
      return allowedNames.contains(l.name) && l.name != currentLocation;
    }).toList();

    availableDestinations.sort((a, b) {
      final ai = int.tryParse(a.name) ?? 0;
      final bi = int.tryParse(b.name) ?? 0;
      return ai.compareTo(bi);
    });

    final visibleLocations = availableDestinations;

    // ★ 目的地ボタンリスト構築
    Widget buildDestinationButtons() {
      // 自分がセレクターでない場合
      if (userId != destinationSelector) {
        return const Center(
          child: Text(
            "パートナーが操作中です\n(目的地・経路選択)",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
        );
      }

      // ロボット移動中
      if (isRobotBusy) {
        return const Center(
            child: Text("目的地へ向かいます",
                style: TextStyle(
                    fontSize: 20,
                    color: Colors.orange,
                    fontWeight: FontWeight.bold)));
      }

      return ListView.separated(
        itemCount: availableDestinations.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final location = availableDestinations[index];
          final bool canPress =
              !isRobotBusy && isAtValidStartLocation && isSystemReady;

          return ElevatedButton(
            onPressed: canPress ? () => sendRequest(location) : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade600,
              disabledBackgroundColor: Colors.grey.shade400,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(location.name,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          );
        },
      );
    }

    // ★ 経路選択ボタンリスト構築
    Widget buildRouteButtons() {
      final routesLeft = routeOptions['route_left'] as List? ?? [];
      final routesCenter = routeOptions['route_center'] as List? ?? [];
      final routesRight = routeOptions['route_right'] as List? ?? [];

      final hasLeft = routesLeft.isNotEmpty;
      final hasCenter = routesCenter.isNotEmpty;
      final hasRight = routesRight.isNotEmpty;

      Widget routeBtn(
          String label, String key, List<dynamic> waypoints, bool isActive) {
        return ElevatedButton(
          onPressed: isActive
              ? () {
                  ref
                      .read(serverCommunicationServiceProvider)
                      .sendRouteSelection(key);
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor:
                isActive ? Colors.green.shade600 : Colors.grey.shade300,
            padding: const EdgeInsets.symmetric(vertical: 20),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Column(
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 4),
              Text(waypoints.join(" -> "),
                  style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ],
          ),
        );
      }

      return Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                if (hasLeft) ...[
                  routeBtn("左ルート", "route_left", routesLeft, true),
                  const SizedBox(height: 12),
                ],
                if (hasCenter) ...[
                  routeBtn("中央ルート", "route_center", routesCenter, true),
                  const SizedBox(height: 12),
                ],
                if (hasRight) ...[
                  routeBtn("右ルート", "route_right", routesRight, true),
                  const SizedBox(height: 12),
                ],
                if (!hasLeft && !hasCenter && !hasRight)
                  const Text("利用可能な経路がありません", textAlign: TextAlign.center),
              ],
            ),
          ),
          // キャンセル用に戻るボタンなどをつけてもよいが、今回は省略
        ],
      );
    }

    // 表示メッセージの制御
    String displayMessage = cooperationMessage;
    if (!isSystemReady) {
      displayMessage = "パートナーの接続を待っています...";
    } else if (!isAtValidStartLocation && !isRobotBusy) {
      displayMessage = "指定外の場所($currentLocation)にいます。\n操作できません。";
    }

    // 右側のパネルエリア
    final Widget questionArea = Expanded(
      flex: 1,
      child: Container(
        color: Colors.grey[200],
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 80,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    !isSystemReady || (!isAtValidStartLocation && !isRobotBusy)
                        ? Colors.grey.shade300
                        : (robotStatus == 'moving'
                            ? Colors.orange.shade100
                            : Colors.blue.shade50),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: !isSystemReady ||
                            (!isAtValidStartLocation && !isRobotBusy)
                        ? Colors.grey.shade500
                        : (robotStatus == 'moving'
                            ? Colors.orange.shade300
                            : Colors.blue.shade200),
                    width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                displayMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16,
                    color: !isSystemReady ||
                            (!isAtValidStartLocation && !isRobotBusy)
                        ? Colors.black54
                        : (robotStatus == 'moving'
                            ? Colors.orange.shade900
                            : Colors.blue.shade900),
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              // UIモードによってタイトル変更
              uiMode == 'route' ? "経路選択 ($targetDestination へ)" : "目的地",
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: 16),
            Expanded(
              // ★ ここでボタンの出し分け
              child: (uiMode == 'route' && userId == destinationSelector)
                  ? buildRouteButtons()
                  : buildDestinationButtons(),
            ),
          ],
        ),
      ),
    );

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        handleKeyEvent(event);
        return KeyEventResult.handled;
      },
      child: Scaffold(
        body: Row(
          children: [
            Expanded(
              flex: 2,
              child: mapInfo == null
                  ? AspectRatio(
                      aspectRatio: 1.0,
                      child: Container(
                          color: const Color(0xFFF8F1F8),
                          child:
                              const Center(child: CircularProgressIndicator())))
                  : AspectRatio(
                      aspectRatio: 1.0,
                      child: MapWidget(
                        mapInfo: mapInfo,
                        pins: [
                          ...visibleLocations.map((e) => _locationPin(e, () {
                                if (!isRobotBusy &&
                                    userId == destinationSelector &&
                                    isAtValidStartLocation &&
                                    isSystemReady &&
                                    uiMode != 'route') {
                                  // ルート選択中はピンタップ無効
                                  sendRequest(e);
                                }
                              })),
                        ],
                        mapTransformState: mapTransformState,
                      ),
                    ),
            ),
            questionArea,
          ],
        ),
      ),
    );
  }

  PinModel _locationPin(Location location, Function() onTap) {
    final pinLabel = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1))
        ],
        border: Border.all(color: Colors.black12, width: 1),
      ),
      child: Text(location.name,
          style: const TextStyle(
              color: Colors.black87,
              fontSize: 10,
              fontWeight: FontWeight.bold)),
    );
    const double estimatedHeight = 18;
    final double estimatedWidth = location.name.length * 10.0 + 16.0;
    return PinModel(
      pose: location.pose,
      pinCenterOffset: Offset(estimatedHeight / 2, estimatedWidth / 2),
      onTap: onTap,
      child: RotatedBox(quarterTurns: 1, child: pinLabel),
    );
  }
}
