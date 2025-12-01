import asyncio
import json
from collections import deque
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from Control import Control
import kachaka_api
import threading
import time
from concurrent.futures import ThreadPoolExecutor

KACHAKA_IP = "10.40.5.108"
app = FastAPI()
kachaka_client: kachaka_api.KachakaApiClient = None

# =================================================================
# Section 1: Kachaka ロボット制御関連
# =================================================================
kachaka_command_queue = deque()
kachaka_clients = set()
kachaka_lock = threading.Lock()
executor = ThreadPoolExecutor(max_workers=1)

# 状態管理変数
user_assignments = {}
# 現在地管理
current_location_name = "充電ドック" 
current_moving_location = None

# 現在の目的地選択権を持つユーザーID (初期値: user_1)
current_destination_selector = "user_1" 

async def send_status_to_all_clients(status_data):
    if not kachaka_clients: return
    disconnected_clients = []
    for client in list(kachaka_clients):
        try:
            await client.send_json(status_data)
        except Exception:
            disconnected_clients.append(client)
    for client in disconnected_clients:
        kachaka_clients.discard(client)

async def broadcast_connection_status():
    is_user1_present = "user_1" in user_assignments.values()
    is_user2_present = "user_2" in user_assignments.values()
    is_ready = is_user1_present and is_user2_present

    message = {
        "type": "connection_status",
        "ready": is_ready,
        "user1": is_user1_present,
        "user2": is_user2_present,
        "destination_selector": current_destination_selector 
    }
    await send_status_to_all_clients(message)

# ★★★ 変更: 経路処理を削除し、直接目的地へ移動する関数に変更 ★★★
async def start_move_to_destination(target_location):
    global kachaka_client
    
    destination_name = target_location["name"]
    print(f"🧐 [Plan] START: '{current_location_name}' -> GOAL: '{destination_name}'")
    
    try:
        if not kachaka_client: return

        locations = kachaka_client.get_locations()
        location_dict = {loc.name: loc for loc in locations}
        
        if destination_name in location_dict:
             dest_loc = location_dict[destination_name]
             final_dest_data = {"id": dest_loc.id, "name": dest_loc.name}
        else:
             print(f"🔥 Destination '{destination_name}' not found!")
             return

        message = f"{destination_name} へ向かいます！"
        
        await send_status_to_all_clients({"type": "STARTING_MOVE", "message": message})
        await asyncio.sleep(1)
        
        with kachaka_lock:
            kachaka_command_queue.append(final_dest_data)
        
    except Exception as e:
        print(f"🔥 Process Error: {e}")

def kachaka_move_sync(location_id, location_name):
    global kachaka_client
    try:
        print(f"🤖 [Move] Trying to go to '{location_name}'...")
        
        timeout = 0
        while kachaka_client.is_command_running():
            time.sleep(0.5)
            timeout += 1
            if timeout > 10: 
                print("⚠️ Force starting new command...")
                break

        kachaka_client.move_to_location(location_id)
        
        time.sleep(1) 
        while kachaka_client.is_command_running():
            time.sleep(0.5)
            
        print(f"✅ [Move] Finished command for '{location_name}'.")
        return True 

    except Exception as e:
        print(f"🔥 [Move] Exception: {e}")
        return True 

async def process_kachaka_queue():
    global kachaka_client, current_location_name, current_moving_location, current_destination_selector
    current_move_future = None

    while True:
        try:
            if not kachaka_client:
                await asyncio.sleep(1); continue
            
            if current_move_future and current_move_future.done():
                if current_moving_location:
                    old_loc = current_location_name
                    new_loc = current_moving_location.get("name")
                    current_location_name = new_loc
                    print(f"📍 [Update] Location changed: '{old_loc}' -> '{new_loc}'")
                
                current_moving_location = None
                
                # ★★★ 役割交代ロジック (到着後) ★★★
                swap_triggers = ["1", "2", "3", "4", "5", "6"]
                
                if current_location_name in swap_triggers:
                    current_destination_selector = "user_2" if current_destination_selector == "user_1" else "user_1"
                    print(f"🔄 [Role Swap] Arrived at {current_location_name}. Destination Selector is now: {current_destination_selector}")
                else:
                    print(f"➡️ [Continue] Arrived at {current_location_name}. No role swap.")

                await send_status_to_all_clients({
                    "type": "kachaka_status", 
                    "status": "idle", 
                    "message": "",
                    "current_location": current_location_name,
                    "destination_selector": current_destination_selector
                })
                current_move_future = None

            if not current_move_future and not kachaka_client.is_command_running():
                with kachaka_lock:
                    if kachaka_command_queue:
                        location_data = kachaka_command_queue.popleft()
                        current_moving_location = location_data
                        
                        await send_status_to_all_clients({"type": "kachaka_status", "status": "moving", "destination": location_data["name"]})
                        
                        loop = asyncio.get_event_loop()
                        current_move_future = loop.run_in_executor(executor, kachaka_move_sync, location_data["id"], location_data["name"])

        except Exception as e:
            print(f"🔥 Queue Error: {e}")
            await asyncio.sleep(5)
        await asyncio.sleep(0.5)

@app.websocket("/ws/kachaka")
async def websocket_kachaka_endpoint(websocket: WebSocket):
    await websocket.accept()
    kachaka_clients.add(websocket)
    user_id = None

    with kachaka_lock:
        if "user_1" not in user_assignments.values(): user_id = "user_1"
        elif "user_2" not in user_assignments.values(): user_id = "user_2"
        else: user_id = "spectator"
        user_assignments[websocket] = user_id
    
    print(f"✅ [Connect] {user_id}. Sending Location: {current_location_name}")
    
    init_msg = ""
    if user_id == current_destination_selector:
        init_msg = "どこに行きますか？"
    else:
        init_msg = "パートナーが目的地を選ぶのを待っています..."

    await websocket.send_json({
        "type": "user_assigned", 
        "user_id": user_id,
        "message": init_msg,
        "current_location": current_location_name,
        "destination_selector": current_destination_selector 
    })

    await broadcast_connection_status()

    try:
        while True:
            data = await websocket.receive_json()
            print(f"📨 [{user_id}] Received: {data}")
            action = data.get("action")

            if action == "REQUEST_DESTINATION":
                if user_id != current_destination_selector:
                     await websocket.send_json({"type": "ERROR", "message": "現在あなたのターンではありません。"})
                     continue

                partner_id = "user_2" if user_id == "user_1" else "user_1"
                if partner_id not in user_assignments.values():
                     await websocket.send_json({"type": "ERROR", "message": "パートナーがいません。"})
                     continue

                if current_moving_location:
                    await websocket.send_json({"type": "ERROR", "message": "移動中です。"})
                    continue
                
                # ★★★ 変更: 経路選択を経ずに即座に移動開始 ★★★
                target_loc = data.get("location")
                await start_move_to_destination(target_loc)

    except WebSocketDisconnect:
        u_id = user_assignments.pop(websocket, None)
        kachaka_clients.discard(websocket)
        if u_id:
            print(f"❌ [Disconnect] {u_id}")
            await send_status_to_all_clients({"type": "user_disconnected", "message": "リセットされました"})
            await broadcast_connection_status()

# =================================================================
# Section 2: Servo Motor Control
# =================================================================
servoRight = Control(physical_id=7, name="Right Servo")
servoLeft = Control(physical_id=5, name="Left Servo")
APP_ID_TO_SERVO_INSTANCE = {1: servoRight, 2: servoLeft}
current_angles = {1: 0, 2: 0}
movement_states = {}
servo_lock = threading.Lock()

def move_servo_by_app_id(app_id, angle):
    with servo_lock:
        servo = APP_ID_TO_SERVO_INSTANCE.get(app_id)
        if servo:
            angle = max(-60, min(angle, 60))
            servo.move(angle)
            current_angles[app_id] = angle

def servo_thread_loop():
    while True:
        try:
            with servo_lock:
                states = dict(movement_states)
            for app_id, direction in states.items():
                if direction != "stop":
                    angle = current_angles.get(app_id, 0)
                    angle += 1.0 if direction == "left" else -1.0
                    move_servo_by_app_id(app_id, angle)
        except Exception: pass
        time.sleep(0.01)

@app.websocket("/ws/servo")
async def websocket_servo_endpoint(websocket: WebSocket):
    await websocket.accept()
    client_app_id = None
    try:
        while True:
            data = await websocket.receive_json()
            command = data.get("command")
            app_id = data.get("app_id")
            if app_id in APP_ID_TO_SERVO_INSTANCE:
                client_app_id = app_id
                with servo_lock:
                    if command.startswith("start_"): movement_states[app_id] = command.split("_")[1]
                    elif command == "stop": movement_states[app_id] = "stop"
    except WebSocketDisconnect: pass
    finally:
        if client_app_id:
            with servo_lock: movement_states[client_app_id] = "stop"

@app.on_event("startup")
async def startup_event():
    global kachaka_client
    print("🚀 Server Starting (Direct Destination Mode)...")
    threading.Thread(target=servo_thread_loop, daemon=True).start()
    try:
        kachaka_client = kachaka_api.KachakaApiClient(f"{KACHAKA_IP}:26400")
        print(f"✅ Connected to Kachaka! Ver: {kachaka_client.get_robot_version()}")
    except Exception as e:
        print(f"🔥 Kachaka connect failed: {e}")
        # asyncio.create_task(retry_kachaka_connection()) 
    
    asyncio.create_task(process_kachaka_queue())
    print("✅ Server Ready")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)