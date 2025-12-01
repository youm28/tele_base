import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:telebase_app/model/map_transform_state.dart';
import 'package:telebase_app/model/pin_model.dart';
import 'package:telebase_app/service/server_communication_service.dart';
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

    const allowedStartLocations = ['充電ドック', '1', '2', '3', '4', '5', '6'];
    final isAtValidStartLocation =
        allowedStartLocations.contains(currentLocation);

    void sendRequest(Location targetLocation) {
      if (robotPose == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("ロボットの現在位置が不明です。")));
        return;
      }
      ref
          .read(serverCommunicationServiceProvider)
          .sendDestinationRequest(targetLocation, robotPose);
    }

    // 目的地リスト: 数値の場所のみ (1,2,3,4,5,6)
    final availableDestinations = locations.where((l) {
      final allowedNames = ['1', '2', '3', '4', '5', '6'];
      // 充電ドックも帰還用に含める場合はここに追加
      return allowedNames.contains(l.name) && l.name != currentLocation;
    }).toList();

    availableDestinations.sort((a, b) {
      final ai = int.tryParse(a.name) ?? 0;
      final bi = int.tryParse(b.name) ?? 0;
      return ai.compareTo(bi);
    });

    final visibleLocations = availableDestinations;

    // ★ 目的地ボタン
    Widget buildDestinationButtons() {
      // 自分が目的地選択担当でない場合
      if (userId != destinationSelector) {
        if (isRobotBusy) {
          return const Center(
            child: Text(
              "目的地へ向かいます",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20,
                  color: Colors.orange,
                  fontWeight: FontWeight.bold),
            ),
          );
        }
        return const Center(
          child: Text(
            "パートナーが目的地を選択するのを\n待っています...",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
        );
      }

      // 自分が目的地選択担当の場合
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

    String displayMessage = cooperationMessage;
    if (!isSystemReady) {
      displayMessage = "パートナーの接続を待っています...";
    } else if (!isAtValidStartLocation && !isRobotBusy) {
      displayMessage = "指定外の場所($currentLocation)にいます。\n操作できません。";
    }

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
            const Text(
              "目的地",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: buildDestinationButtons(),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
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
                                  isSystemReady) {
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
