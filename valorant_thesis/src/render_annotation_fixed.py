# render_annotation_fixed.py
import cv2
import numpy as np
import json
import os

def create_tracking_highlight(base_video_path, json_path, output_path):
    # データ読み込み
    print("📂 JSONデータを読み込んでいます...")
    with open(json_path, "r") as f:
        data = json.load(f)
    
    events = data['events']
    trails = data['trails']
    fps = data['fps']
    
    # フレーム番号ごとにキャラ位置を辞書化
    frame_map = {}
    for t in trails:
        f = t['frame']
        c = t['class']
        if f not in frame_map: frame_map[f] = {}
        frame_map[f][c] = {'x': t['x'], 'y': t['y']}
    print("✅ 軌跡データの整理完了")

    # 動画読み込み
    cap = cv2.VideoCapture(base_video_path)
    clean_path = base_video_path.replace(".mp4", "_clean.mp4")
    if not os.path.exists(clean_path):
        print("⚠️ クリーン動画が見つかりません。analyze_local_pt.pyを再実行してください。")
        cap_clean = cv2.VideoCapture(base_video_path)
    else:
        cap_clean = cv2.VideoCapture(clean_path)

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
    out = cv2.VideoWriter(output_path, cv2.VideoWriter_fourcc(*'mp4v'), fps, (width, height))
    
    # --- 設定 ---
    KILL_PRE  = int(fps * 3.0) 
    KILL_POST = int(fps * 3.0) 
    SPIKE_PRE = int(fps * 3.0)
    SPIKE_POST = int(fps * 2.0)
    FOCAL_PRE = int(fps * 5.0)   
    FOCAL_POST = int(fps * 3.0) 

    # ★変更点: ここで「重要イベント区間」を事前に計算し、スピード調整を行います
    print("⏱️ 30秒に収めるための再生速度を計算中...")
    
    # 全フレームについて「イベント中かどうか」を判定するフラグ配列
    is_event_frame = np.zeros(total_frames, dtype=bool)

    for ev in events:
        start_f, end_f = 0, 0
        if ev['type'] == "spike_plant":
            start_f = ev['frame'] - SPIKE_PRE
            end_f   = ev['frame'] + SPIKE_POST
        elif ev['type'] == "focal_point":
            start_f = ev['frame'] - FOCAL_PRE
            end_f   = ev['frame'] + FOCAL_POST
        else: # kill events
            start_f = ev['frame'] - KILL_PRE
            end_f   = ev['frame'] + KILL_POST
        
        # 配列範囲内に収める
        s = max(0, int(start_f))
        e = min(total_frames, int(end_f))
        is_event_frame[s:e] = True

    # フレーム数カウント
    event_frames_count = np.sum(is_event_frame) # 等倍で再生するフレーム数
    normal_frames_count = total_frames - event_frames_count # 倍速するフレーム数

    TARGET_DURATION_SEC = 30.0
    target_total_output_frames = int(TARGET_DURATION_SEC * fps)

    # イベント部分だけで何秒使うか
    time_for_events = event_frames_count # 1フレーム=1出力フレーム

    # 残りのフレーム（移動パート）に使える出力フレーム数
    available_frames_for_normal = target_total_output_frames - time_for_events

    speed_multiplier = 1.0
    if available_frames_for_normal <= 0:
        print(f"⚠️ 警告: イベントシーンだけで30秒を超えています！({time_for_events/fps:.1f}秒)")
        print("移動パートを極限までカットします。")
        speed_multiplier = 100.0 # ほぼスキップ
    else:
        # (移動パートの実フレーム数) / (使える出力フレーム数) = 倍速レート
        speed_multiplier = normal_frames_count / available_frames_for_normal
        print(f"✅ イベント時間: {time_for_events/fps:.1f}秒, 移動パート時間: {available_frames_for_normal/fps:.1f}秒")
        print(f"🚀 移動パートの再生速度: {speed_multiplier:.2f}倍速 に設定しました")

    # --- その他の設定 ---
    MINIMAP_OFFSET_X = 0
    MINIMAP_OFFSET_Y = 0

    SMOOTH_FACTOR = 0.1     
    ZOOM_SIZE_PIXELS = 100  
    TARGET_ZOOM_LEVEL = width / (ZOOM_SIZE_PIXELS * 2) 

    current_zoom = 1.0
    cam_center_x = width / 2.0
    cam_center_y = height / 2.0

    COLOR_KILLER = (0, 255, 255) 
    COLOR_VICTIM = (0, 0, 255)   
    COLOR_ARROW  = (0, 255, 255) 
    COLOR_SPIKE  = (255, 0, 255) 
    COLOR_FOCAL  = (0, 255, 0)   
    COLOR_TEXT   = (255, 255, 255)
    
    TL_BG_COLOR     = (50, 50, 50)    
    TL_NORMAL_COLOR = (100, 100, 100) 
    TL_EVENT_COLOR  = (0, 0, 255)
    TL_FOCAL_COLOR  = (0, 255, 0)
    TL_CURSOR_COLOR = (255, 255, 255) 
    BAR_HEIGHT = 30

    def get_dynamic_pos(frame_idx, class_name):
        idx = int(frame_idx) # float対応
        if idx in frame_map and class_name in frame_map[idx]:
            p = frame_map[idx][class_name]
            return {"x": p['x'] + MINIMAP_OFFSET_X, "y": p['y'] + MINIMAP_OFFSET_Y}
        return None

    def get_last_known_pos(frame_idx, class_name, lookback=30):
        idx = int(frame_idx)
        for i in range(lookback):
            target_f = idx - i
            if target_f < 0: break
            # 内部でintキャストして呼ぶ
            pos = get_dynamic_pos(target_f, class_name)
            if pos: return pos
        return None

    # タイムライン画像の生成（固定）
    timeline_img = np.zeros((BAR_HEIGHT, width, 3), dtype=np.uint8)
    timeline_img[:] = TL_BG_COLOR 
    for ev in events:
        if ev['type'] == "focal_point":
            start_f = max(0, ev['frame'] - FOCAL_PRE)
            end_f   = min(total_frames, ev['frame'] + FOCAL_POST)
            x_start = int((start_f / total_frames) * width)
            x_end   = int((end_f / total_frames) * width)
            cv2.rectangle(timeline_img, (x_start, 0), (x_end, BAR_HEIGHT), TL_FOCAL_COLOR, -1)
    for ev in events:
        is_imp = ev['type'] in ["spike_plant", "kill", "multi_kill", "first_blood", "last_kill"]
        if is_imp:
            if ev['type'] == "spike_plant":
                start_f = max(0, ev['frame'] - SPIKE_PRE)
                end_f   = min(total_frames, ev['frame'] + SPIKE_POST)
            else:
                start_f = max(0, ev['frame'] - KILL_PRE)
                end_f   = min(total_frames, ev['frame'] + KILL_POST)
            x_start = int((start_f / total_frames) * width)
            x_end   = int((end_f / total_frames) * width)
            cv2.rectangle(timeline_img, (x_start, 0), (x_end, BAR_HEIGHT), TL_EVENT_COLOR, -1)

    print(f"--- 動画生成開始 ---")
    
    # float型でフレーム管理（小数点以下の進行を許容するため）
    current_input_frame = 0.0
    output_frame_count = 0
    
    while current_input_frame < total_frames:
        current_frame_int = int(current_input_frame)
        
        # 現在のフレームがイベント期間内かどうか
        in_event = is_event_frame[current_frame_int] if current_frame_int < total_frames else False
        
        # アクティブなイベントを取得（表示用）
        active_event = None
        candidates = []
        for ev in events:
            if ev['type'] == "spike_plant":
                start = ev['frame'] - SPIKE_PRE
                end = ev['frame'] + SPIKE_POST
            elif ev['type'] == "focal_point":
                start = ev['frame'] - FOCAL_PRE
                end = ev['frame'] + FOCAL_POST
            else: 
                start = ev['frame'] - KILL_PRE
                end = ev['frame'] + KILL_POST
            
            if start <= current_input_frame <= end:
                candidates.append(ev)
        
        if candidates:
            def get_priority(e):
                t = e['type']
                if t in ["kill", "multi_kill", "first_blood", "last_kill"]: return 100
                if t == "spike_plant": return 50
                if t == "focal_point": return 10
                return 0
            active_event = max(candidates, key=get_priority)
        
        # フレーム同期読み込み
        cap.set(cv2.CAP_PROP_POS_FRAMES, current_frame_int)
        cap_clean.set(cv2.CAP_PROP_POS_FRAMES, current_frame_int)
        
        ret, frame_trails = cap.read()
        ret2, frame_clean = cap_clean.read()
        
        if not ret or not ret2: break
        
        # イベント中またはズーム中はクリーン映像、それ以外は軌跡あり
        if active_event:
            frame = frame_clean 
        else:
            frame = frame_trails 
        
        # --- ターゲット決定 & ズームロジック ---
        target_center_x = width / 2.0
        target_center_y = height / 2.0
        target_zoom = 1.0
        ev_type = None
        
        if active_event:
            ev_type = active_event['type']
            target_pos = None

            if ev_type == "spike_plant":
                if active_event.get('k_pos'):
                    raw = active_event['k_pos']
                    target_pos = {"x": raw['x'] + MINIMAP_OFFSET_X, "y": raw['y'] + MINIMAP_OFFSET_Y}
            elif ev_type == "focal_point":
                if active_event.get('k_pos'):
                    raw = active_event['k_pos']
                    target_pos = {"x": raw['x'] + MINIMAP_OFFSET_X, "y": raw['y'] + MINIMAP_OFFSET_Y}
            else:
                killer_cls = active_event['killer']
                victim_cls = active_event['victim']
                kp = get_dynamic_pos(current_frame_int, killer_cls) or get_last_known_pos(current_frame_int, killer_cls)
                vp = None
                # 位置補完ロジック
                if current_frame_int >= active_event['frame']:
                     vp = get_dynamic_pos(active_event['frame'], victim_cls) or get_last_known_pos(active_event['frame'], victim_cls, 30)
                else:
                     vp = get_dynamic_pos(current_frame_int, victim_cls) or get_last_known_pos(current_frame_int, victim_cls, 60)
                
                if not kp and active_event.get('k_pos'):
                    raw_k = active_event['k_pos']
                    kp = {"x": raw_k['x'], "y": raw_k['y']}
                if not vp and active_event.get('v_pos'):
                    raw_v = active_event['v_pos']
                    vp = {"x": raw_v['x'], "y": raw_v['y']}

                if ev_type in ["multi_kill", "first_blood"]: target_pos = kp
                else: target_pos = vp 
                if not target_pos: target_pos = kp if kp else vp

            if target_pos:
                target_center_x = target_pos['x']
                target_center_y = target_pos['y']
                target_zoom = TARGET_ZOOM_LEVEL

        # スムーズ化 (Viewer Timeに対してスムーズに動くため、ここは毎ループ実行でOK)
        current_zoom = current_zoom * (1 - SMOOTH_FACTOR) + target_zoom * SMOOTH_FACTOR
        cam_center_x = cam_center_x * (1 - SMOOTH_FACTOR) + target_center_x * SMOOTH_FACTOR
        cam_center_y = cam_center_y * (1 - SMOOTH_FACTOR) + target_center_y * SMOOTH_FACTOR

        # 切り抜き処理
        crop_w = width / current_zoom
        crop_h = height / current_zoom
        x1 = max(0, min(cam_center_x - crop_w / 2, width - crop_w))
        y1 = max(0, min(cam_center_y - crop_h / 2, height - crop_h))
        x2 = x1 + crop_w
        y2 = y1 + crop_h
        
        if x2 > width: x1 = width - crop_w; x2 = width
        if y2 > height: y1 = height - crop_h; y2 = height
        if x1 < 0: x1 = 0; x2 = crop_w
        if y1 < 0: y1 = 0; y2 = crop_h

        cropped_frame = frame[int(y1):int(y2), int(x1):int(x2)]
        if cropped_frame.size == 0:
            final_frame = frame
        else:
            final_frame = cv2.resize(cropped_frame, (width, height), interpolation=cv2.INTER_LINEAR)

        # アノテーション描画 (active_eventがある場合)
        if active_event and target_pos:
            scale_x = width / crop_w
            scale_y = height / crop_h
            def to_zoomed_pos(abs_pos):
                zx = int((abs_pos['x'] - x1) * scale_x)
                zy = int((abs_pos['y'] - y1) * scale_y)
                return (zx, zy)

            if ev_type == "spike_plant":
                sp_z = to_zoomed_pos(target_pos)
                cv2.rectangle(final_frame, (sp_z[0]-20, sp_z[1]-20), (sp_z[0]+20, sp_z[1]+20), COLOR_SPIKE, 3)
                cv2.putText(final_frame, "SPIKE PLANT", (sp_z[0]-50, sp_z[1]-30), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, COLOR_SPIKE, 2)

            elif ev_type == "focal_point":
                fp_z = to_zoomed_pos(target_pos)
                detail_name = active_event.get('type_detail', '')
                if "astra_ult" in detail_name:
                    cv2.rectangle(final_frame, (fp_z[0]-30, fp_z[1]-30), (fp_z[0]+30, fp_z[1]+30), COLOR_FOCAL, 3)
                else:
                    cv2.circle(final_frame, fp_z, 30, COLOR_FOCAL, 3)

                cat_label = active_event.get('category', 'TACTICAL').upper()
                detail_label = active_event.get('type_detail', '').replace("_", " ").upper()
                cv2.putText(final_frame, cat_label, (fp_z[0]-40, fp_z[1]-45), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, COLOR_FOCAL, 2)
                cv2.putText(final_frame, detail_label, (fp_z[0]-40, fp_z[1]+60), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, COLOR_TEXT, 1)

            else:
                killer_cls = active_event['killer']
                victim_cls = active_event['victim']
                kp = get_dynamic_pos(current_frame_int, killer_cls) or get_last_known_pos(current_frame_int, killer_cls)
                vp = None
                if current_frame_int >= active_event['frame']:
                     vp = get_dynamic_pos(active_event['frame'], victim_cls) or get_last_known_pos(active_event['frame'], victim_cls, 30)
                else:
                     vp = get_dynamic_pos(current_frame_int, victim_cls) or get_last_known_pos(current_frame_int, victim_cls, 60)
                
                if not kp and active_event.get('k_pos'):
                    raw_k = active_event['k_pos']
                    kp = {"x": raw_k['x'], "y": raw_k['y']}
                if not vp and active_event.get('v_pos'):
                    raw_v = active_event['v_pos']
                    vp = {"x": raw_v['x'], "y": raw_v['y']}

                kp_z = to_zoomed_pos(kp) if kp else None
                vp_z = to_zoomed_pos(vp) if vp else None

                if kp_z and vp_z:
                    cv2.arrowedLine(final_frame, kp_z, vp_z, COLOR_ARROW, 4, tipLength=0.3)
                if kp_z:
                    cv2.rectangle(final_frame, (kp_z[0]-15, kp_z[1]-15), (kp_z[0]+15, kp_z[1]+15), COLOR_KILLER, 2)
                    cv2.putText(final_frame, "KILLER", (kp_z[0]-25, kp_z[1]-20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, COLOR_KILLER, 2)
                if vp_z:
                    cv2.rectangle(final_frame, (vp_z[0]-15, vp_z[1]-15), (vp_z[0]+15, vp_z[1]+15), COLOR_VICTIM, 2)
                    cv2.putText(final_frame, "VICTIM", (vp_z[0]-25, vp_z[1]-20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, COLOR_VICTIM, 2)
            
            # 枠
            cv2.rectangle(final_frame, (0,0), (width, height), (0, 255, 255), 10)
            if ev_type == "focal_point": label = "CONTRIBUTION"
            else: label = ev_type.replace("_", " ").upper()
            cv2.putText(final_frame, label, (20, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255,255,255), 3)

        # タイムライン合成
        y_pos = height - BAR_HEIGHT - 20
        if y_pos + BAR_HEIGHT <= height:
            final_frame[y_pos:y_pos+BAR_HEIGHT, 0:width] = timeline_img
            cursor_x = int((current_input_frame / total_frames) * width)
            cv2.line(final_frame, (cursor_x, y_pos - 5), (cursor_x, y_pos + BAR_HEIGHT + 5), TL_CURSOR_COLOR, 3)

        out.write(final_frame)
        cv2.imshow("Highlight View Generator", final_frame)
        
        # --- フレーム進行制御 ---
        output_frame_count += 1
        
        # 進行速度の決定
        if in_event:
            step = 1.0 # 等倍
        else:
            step = speed_multiplier # 計算された倍速
            
        current_input_frame += step

        if cv2.waitKey(1) & 0xFF == ord('q'): break
        if output_frame_count % 50 == 0:
            print(f"\r出力中: {output_frame_count}/{target_total_output_frames} Frames (Input: {int(current_input_frame)}/{total_frames})", end="")

    cap.release()
    cap_clean.release()
    out.release()
    cv2.destroyAllWindows()
    print(f"\n✅ 完成！出力: {output_path}")

if __name__ == "__main__":
    create_tracking_highlight("base_minimap.mp4", "match_data.json", "Final_Tracking_30s.mp4")