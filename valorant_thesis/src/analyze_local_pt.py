import cv2
import numpy as np
import json
import sys
import math
from collections import Counter
from ultralytics import YOLO

class ValorantAnalyzerV2:
    def __init__(self, model_path="best.pt"):
        print(f"🔄 モデルを読み込んでいます: {model_path}...")
        try:
            self.model = YOLO(model_path)
            print("✅ モデル読み込み成功！スコア閾値厳格化版(v4)")
        except Exception as e:
            print(f"❌ モデル読み込みエラー: {e}")
            sys.exit()
            
        # 座標定義 (x, y, w, h)
        self.minimap_coords = (35, 140, 365, 340)   
        self.kill_feed_coords = (1207, 165, 440, 70) 
        self.spike_ui_coords = (748, 96, 162, 93)
        
        self.trail_data = [] 
        self.events = []
        
        # 焦点ポイント(貢献行動)用のアビリティラベル定義
        self.TACTICAL_LABELS = {
            # エリアコントロール
            "smoke": "Area Control",
            "smoke_friend": "Area Control",
            "smoke_enemy": "Area Control",
            "astra_ult_enemy": "Ultimate",
            "astra_ult_friend": "Ultimate",
            "viper_pit_enemy": "Ultimate",
            "viper_pit_friend": "Ultimate",
            
            # 索敵行動
            "fade_haunt_f": "Recon",
            "fade_prowler_f": "Recon",
            "sova_drone_e": "Recon",
            "sova_recon_e": "Recon",
            "skye_dog_e": "Recon",
            "skye_bird_e": "Recon"
        }

    def run_analysis(self, video_path):
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            print("❌ 動画が開けません")
            return

        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS)
        
        print(f"--- 1. データ分析開始 (全{total_frames}フレーム) ---")
        
        raw_detections = [] 
        is_spike_planted = False

        # ★低信頼度(8%)でも検出を許容するアビリティリスト
        LOW_CONF_LABELS = {
            "astra_star_enemy",
            "astra_star_friend",
            "astra_ult_enemy",
            "fade_haunt_f",
            "fade_prowler_f",
            "smoke",
            "sova_drone_e",
            "sova_recon_e"
        }
        
        for current_frame in range(total_frames):
            ret, frame = cap.read()
            if not ret: break

            # --- 1. ミニマップ検出 ---
            mx, my, mw, mh = self.minimap_coords
            minimap_img = frame[my:my+mh, mx:mx+mw]
            
            current_minimap_objs = []
            
            # ★変更: 全体の足切りラインを 0.08 (8%) に下げる
            results = self.model.predict(minimap_img, conf=0.08, verbose=False)
            
            for r in results:
                for box in r.boxes:
                    cls_id = int(box.cls[0])
                    cls_name = self.model.names[cls_id]
                    conf = float(box.conf[0])
                    
                    # ★変更: ラベルごとに閾値を分岐させる
                    if cls_name in LOW_CONF_LABELS:
                        # アビリティリストにある場合は 8% 以上ならOK
                        if conf < 0.08: continue
                    else:
                        # リストにないもの（エージェントなど）は 25% 以上でなければ弾く
                        if conf < 0.25: continue

                    x, y, w, h = box.xywh[0]
                    
                    if w < 5 or h < 5: continue
                    
                    color = (0, 255, 0) if cls_name.endswith('f') else ((0, 0, 255) if cls_name.endswith('e') else (0, 255, 255))
                    obj_data = {
                        "frame": current_frame,
                        "class": cls_name,
                        "x": int(x), "y": int(y), 
                        "color": color
                    }
                    self.trail_data.append(obj_data)
                    current_minimap_objs.append(obj_data)

            # --- 2. キルログ検出 ---
            if current_frame % 3 == 0:
                kx, ky, kw, kh = self.kill_feed_coords
                h_img, w_img, _ = frame.shape
                if ky+kh <= h_img and kx+kw <= w_img:
                    kill_img = frame[ky:ky+kh, kx:kx+kw]
                    k_results = self.model.predict(kill_img, conf=0.20, verbose=False)
                    preds = []
                    for r in k_results:
                        for box in r.boxes:
                            cls_id = int(box.cls[0])
                            cls_name = self.model.names[cls_id]
                            preds.append({
                                'class': cls_name,
                                'x': int(box.xywh[0][0]), 
                                'confidence': float(box.conf[0])
                            })
                    pair_result = self._find_best_kill_pair_strict(preds)
                    if pair_result:
                        killer, victim, _ = pair_result
                        raw_detections.append({
                            "frame": current_frame,
                            "killer": killer,
                            "victim": victim
                        })

            # --- 3. スパイク設置検出 ---
            if not is_spike_planted and current_frame % 3 == 0:
                sx, sy, sw, sh = self.spike_ui_coords
                h_img, w_img, _ = frame.shape
                
                if sy+sh <= h_img and sx+sw <= w_img:
                    spike_ui_img = frame[sy:sy+sh, sx:sx+sw]
                    # 閾値を0.50に設定
                    s_results = self.model.predict(spike_ui_img, conf=0.50, verbose=False)
                    
                    ui_detected = False
                    for r in s_results:
                        for box in r.boxes:
                            c_name = self.model.names[int(box.cls[0])]
                            if c_name == "ui_spike_plant":
                                ui_detected = True
                                break
                    
                    if ui_detected:
                        spike_pos = None
                        for obj in current_minimap_objs:
                            if obj['class'] == "minimap_spike":
                                spike_pos = {"x": obj['x'], "y": obj['y']}
                                break
                        
                        if spike_pos and spike_pos['y'] < 200:
                            print(f"💣 スパイク設置確定! Frame: {current_frame}, Pos: {spike_pos}")
                            self.events.append({
                                "frame": current_frame,
                                "type": "spike_plant",
                                "killer": "Spike",
                                "victim": "Site",
                                "k_pos": spike_pos,
                                "v_pos": spike_pos
                            })
                            is_spike_planted = True

            if current_frame % 100 == 0:
                sys.stdout.write(f"\r分析中: {(current_frame/total_frames)*100:.1f}%")
                sys.stdout.flush()

        # --- イベント整理 ---
        print("\n--- 分析完了。イベント整理中... ---")
        
        self._classify_smokes(fps)
        confirmed_kills = self._stabilize_kills_tuned(raw_detections, fps)
        
        if confirmed_kills:
            confirmed_kills.sort(key=lambda x: x['frame'])
            last_kill_time_by_player = {} 

            for i, kill in enumerate(confirmed_kills):
                event_type = "kill" 
                killer_name = kill['killer']
                
                if i == 0: event_type = "first_blood"
                elif i == len(confirmed_kills) - 1: event_type = "last_kill"
                else:
                    if killer_name in last_kill_time_by_player:
                        prev_time = last_kill_time_by_player[killer_name]
                        if (kill['frame'] - prev_time) < (fps * 3.0):
                            event_type = "multi_kill"
                
                last_kill_time_by_player[killer_name] = kill['frame']

                if event_type in ["first_blood", "multi_kill", "last_kill"]:
                    k_pos = self._find_agent_pos(kill['frame'], kill['killer'], search_range=90, look_back=True)
                    v_pos = self._find_agent_pos(kill['frame'], kill['victim'], search_range=90, look_back=True)
                    self.events.append({
                        "frame": kill['frame'],
                        "type": event_type,
                        "killer": kill['killer'],
                        "victim": kill['victim'],
                        "k_pos": k_pos,
                        "v_pos": v_pos
                    })

        # 3. 焦点ポイント(貢献行動)の算出
        self._analyze_focal_points(fps)

        # 保存
        self.events.sort(key=lambda x: x['frame'])
        with open("match_data.json", "w") as f:
            json.dump({"events": self.events, "trails": self.trail_data, "fps": fps}, f)
        
        print("--- 2. ベース動画生成（戦術的軌跡モード） ---")
        self.export_base_video_lines(video_path, "base_minimap.mp4")

    # --- 補助関数群 ---
    
    def _classify_smokes(self, fps):
        print("🌫️ スモークの敵味方識別中...")
        stars_map = {'friend': [], 'enemy': []}
        for t in self.trail_data:
            if t['class'] == 'astra_star_friend':
                stars_map['friend'].append(t)
            elif t['class'] == 'astra_star_enemy':
                stars_map['enemy'].append(t)
        
        count_classified = 0
        SEARCH_RADIUS = 30
        SEARCH_TIME_SEC = 5.0
        
        for t in self.trail_data:
            if t['class'] == 'smoke':
                frame = t['frame']
                pos = np.array([t['x'], t['y']])
                
                found_type = None
                min_dist = 999
                min_frame = frame - int(fps * SEARCH_TIME_SEC)
                
                for star in stars_map['friend']:
                    if min_frame <= star['frame'] <= frame:
                        d = np.linalg.norm(pos - np.array([star['x'], star['y']]))
                        if d < SEARCH_RADIUS and d < min_dist:
                            min_dist = d
                            found_type = 'smoke_friend'

                for star in stars_map['enemy']:
                    if min_frame <= star['frame'] <= frame:
                        d = np.linalg.norm(pos - np.array([star['x'], star['y']]))
                        if d < SEARCH_RADIUS and d < min_dist:
                            min_dist = d
                            found_type = 'smoke_enemy'
                
                if found_type:
                    t['class'] = found_type
                    count_classified += 1
        print(f"✅ スモーク分類完了: {count_classified}個のsmokeを識別しました。")

    def _analyze_focal_points(self, fps):
        """
        貢献行動(Focal Point)を算出
        """
        print("💡 貢献行動(焦点ポイント)を算出中...")
        
        ability_actions = [t for t in self.trail_data if t['class'] in self.TACTICAL_LABELS]
        new_focal_events = []
        
        for ev in self.events:
            if ev['type'] in ["focal_point"]: continue 
            
            ev_frame = ev['frame']
            ev_pos = ev['k_pos'] if ev['k_pos'] else ev['v_pos']
            if not ev_pos: continue
            
            best_ability = None
            max_score = -1
            
            WINDOW_MIN = 1.0 
            WINDOW_MAX = 10.0
            
            for ab in ability_actions:
                # ★修正: スパイク設置時は、敵チームの行動なので味方アビリティを除外する
                if ev['type'] == 'spike_plant':
                    cls_name = ab['class']
                    # 味方タグが含まれるものはスキップ
                    if "friend" in cls_name or cls_name.endswith("_f"):
                        continue
                
                delta_frames = ev_frame - ab['frame']
                delta_t = delta_frames / fps
                
                if WINDOW_MIN < delta_t < WINDOW_MAX:
                    dist = math.sqrt((ev_pos['x'] - ab['x'])**2 + (ev_pos['y'] - ab['y'])**2)
                    if dist < 1.0: dist = 1.0
                    
                    score = (1.0 / (delta_t ** 2)) * (1.0 / dist)
                    
                    if score > max_score:
                        max_score = score
                        best_ability = ab
            
            if best_ability and max_score > 0.01:
                is_duplicate = False
                for fe in new_focal_events:
                    if fe['type_detail'] == best_ability['class'] and abs(fe['frame'] - best_ability['frame']) < 10:
                        is_duplicate = True
                        break
                
                if not is_duplicate:
                    tactical_type = self.TACTICAL_LABELS[best_ability['class']]
                    new_focal_events.append({
                        "frame": best_ability['frame'],
                        "type": "focal_point", 
                        "type_detail": best_ability['class'],
                        "category": tactical_type, 
                        "killer": tactical_type,   
                        "victim": "",
                        "k_pos": {"x": best_ability['x'], "y": best_ability['y']},
                        "v_pos": None
                    })
        
        print(f"✅ {len(new_focal_events)}件の貢献行動を追加しました。")
        self.events.extend(new_focal_events)

    def _find_best_kill_pair_strict(self, preds):
        if len(preds) < 2: return None
        row_sorted = sorted(preds, key=lambda x: x['x'])
        min_x = row_sorted[0]['x']
        max_x = row_sorted[-1]['x']
        if (max_x - min_x) < 50: return None
        killers = [p for p in row_sorted if p['x'] < min_x + 40]
        victims = [p for p in row_sorted if p['x'] > max_x - 40]
        best_pair = None
        best_score = -999
        for k in killers:
            for v in victims:
                if k == v: continue
                if k['class'][-1] == v['class'][-1]: continue
                score = k['confidence'] + v['confidence']
                if score > best_score:
                    best_score = score
                    best_pair = (k['class'], v['class'])
        if best_pair: return (best_pair[0], best_pair[1], "")
        return None

    def _stabilize_kills_tuned(self, raw_detections, fps):
        if not raw_detections: return []
        groups = []
        current_group = [raw_detections[0]]
        for i in range(1, len(raw_detections)):
            prev = raw_detections[i-1]
            curr = raw_detections[i]
            if (curr['victim'] == prev['victim']) and (curr['frame'] - prev['frame'] < fps * 2.0):
                current_group.append(curr)
            else:
                groups.append(current_group)
                current_group = [curr]
        groups.append(current_group)
        temp_results = []
        for group in groups:
            if len(group) < 2: continue
            killers = [g['killer'] for g in group]
            m_killer = Counter(killers).most_common(1)[0][0]
            victims = [g['victim'] for g in group]
            m_victim = Counter(victims).most_common(1)[0][0]
            center_frame = group[len(group)//2]['frame']
            temp_results.append({"frame": center_frame, "killer": m_killer, "victim": m_victim})
        final_results = []
        accepted_history = []
        for curr in temp_results:
            is_duplicate = False
            for past in accepted_history:
                if (past['killer'] == curr['killer'] and past['victim'] == curr['victim']) and (curr['frame'] - past['frame'] < fps * 5.0):
                    is_duplicate = True
                    break
            if not is_duplicate:
                final_results.append(curr)
                accepted_history.append(curr)
        return final_results

    def _find_agent_pos(self, frame, agent_name, search_range=90, look_back=False):
        if look_back:
            candidates = [t for t in self.trail_data 
                          if (frame - t['frame']) >= 0 and (frame - t['frame']) < search_range 
                          and t['class'] == agent_name]
        else:
            candidates = [t for t in self.trail_data 
                          if abs(t['frame'] - frame) < search_range 
                          and t['class'] == agent_name]
        if candidates:
            best = min(candidates, key=lambda x: abs(x['frame'] - frame))
            return {"x": best['x'], "y": best['y']}
        return None

    def export_base_video_lines(self, video_path, output_path):
        cap = cv2.VideoCapture(video_path)
        fps = cap.get(cv2.CAP_PROP_FPS)
        mx, my, mw, mh = self.minimap_coords
        
        out = cv2.VideoWriter(output_path, cv2.VideoWriter_fourcc(*'mp4v'), fps, (mw, mh))
        clean_path = output_path.replace(".mp4", "_clean.mp4")
        out_clean = cv2.VideoWriter(clean_path, cv2.VideoWriter_fourcc(*'mp4v'), fps, (mw, mh))
        
        trails_map = {}
        for t in self.trail_data:
            if t['frame'] not in trails_map: trails_map[t['frame']] = []
            trails_map[t['frame']].append(t)

        canvas = np.zeros((mh, mw, 3), dtype=np.uint8)
        last_positions = {}
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        
        # 指定された除外リスト
        EXCLUDE_LABELS = {
            "astra_star_enemy",
            "astra_star_friend",
            "astra_ult_enemy",
            "fade_haunt_f",
            "fade_prowler_f",
            "minimap_spike",
            "smoke",
            "sova_drone_e",
            "sova_recon_e",
            "ui_spike_defuse",
            "ui_spike_plant"
        }

        print("--- 軌跡動画生成中（指定ラベル以外をすべて描画） ---")
        
        for i in range(total):
            ret, frame = cap.read()
            if not ret: break
            mini = frame[my:my+mh, mx:mx+mw]
            
            if i in trails_map:
                for t in trails_map[i]:
                    cls = t['class']
                    # リストに含まれる場合のみスキップ
                    if cls in EXCLUDE_LABELS:
                        continue
                    
                    curr_pos = (t['x'], t['y'])
                    color = tuple(t['color'])
                    
                    if cls in last_positions:
                        prev_pos = last_positions[cls]
                        dist = np.linalg.norm(np.array(curr_pos) - np.array(prev_pos))
                        if dist < 50: 
                            cv2.line(canvas, prev_pos, curr_pos, color, 1, cv2.LINE_AA) 
                    
                    cv2.circle(canvas, curr_pos, 1, color, -1)
                    last_positions[cls] = curr_pos
            
            final = cv2.addWeighted(mini, 1.0, canvas, 0.6, 0)
            
            if i in trails_map:
                for t in trails_map[i]:
                    cls = t['class']
                    if cls in EXCLUDE_LABELS: continue
                    icon_r = 9 
                    cx, cy = t['x'], t['y']
                    y1 = max(0, cy - icon_r)
                    y2 = min(mh, cy + icon_r)
                    x1 = max(0, cx - icon_r)
                    x2 = min(mw, cx + icon_r)
                    try:
                        final[y1:y2, x1:x2] = mini[y1:y2, x1:x2]
                    except:
                        pass

            out.write(final)
            out_clean.write(mini)
            if i % 100 == 0: sys.stdout.write(f"\r生成中: {(i/total)*100:.1f}%")
        
        cap.release()
        out.release()
        out_clean.release()
        print(f"\n✅ 完了！ render_annotation_fixed.py を実行してください。")

if __name__ == "__main__":
    analyzer = ValorantAnalyzerV2("best.pt")
    analyzer.run_analysis("round_video.mp4")