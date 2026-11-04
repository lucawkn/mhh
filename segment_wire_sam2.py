# -*- coding: utf-8 -*-
"""
segment_wire_sam2.py
====================
Segmentiert einen Draht in einem .avi-Video ODER einer JPG-Bildsequenz mit dem
Segment Anything Model 2 (SAM 2, Meta) und speichert die Masken als PNG-Ordner
neben dem Video bzw. neben dem Bilderordner.

Workflow (Vorverarbeitung fuer kruemung_jinhan.m [Video] / kruemung.m [Ordner]):
  1. Auswahlfenster: "Video (.avi)" oder "Bilderordner (.jpg)".
  2. Auswahlfenster: "Eins" oder "Mehrere".
       - Eins:     Datei- bzw. Ordner-Dialog fuer EIN Video / EINEN Bilderordner.
       - Mehrere:  Ordner-Dialog fuer einen UEBERORDNER. Verarbeitet werden
                   alle .avi-Dateien darin bzw. alle Unterordner, die .jpg-
                   Bilder enthalten (jeweils alphabetisch sortiert).
     Alle Dialoge starten im DEFAULT_PATH.
  3. PROMPT-PHASE: Nacheinander wird fuer JEDES Video / jeden Bilderordner der
     PROMPT_FRAME-te Frame angezeigt (Default: 10.; die ersten Frames sind oft
     verzerrt und ungeeignet): Draht anklicken.
       - Linksklick  = Punkt gehoert ZUM Draht (positiv, gruenes +)
       - Rechtsklick = Punkt gehoert NICHT zum Draht (negativ, rotes x)
       - Taste 'u'   = letzten Punkt entfernen
       - Enter       = bestaetigen, weiter zum naechsten Video/Ordner
     Nach jedem Klick wird die aktuelle SAM-2-Maske als Overlay angezeigt.
     Fenster ohne positiven Klick schliessen = dieses Video/diesen Ordner
     ueberspringen (bei "Eins": Abbruch).
  4. SEGMENTIER-PHASE (erst wenn alle Prompts gesetzt sind, laeuft ohne
     weitere Eingaben durch): pro Video/Ordner werden alle Frames in einen
     temporaeren JPEG-Ordner extrahiert bzw. kopiert (das erwartet der SAM-2-
     Video-Predictor) und SAM 2 propagiert die Maske in BEIDE Richtungen
     (vorwaerts und rueckwaerts ab dem Prompt-Frame) durch ALLE Frames.
     Bei Bilderordnern werden die JPGs ALPHABETISCH sortiert - dieselbe
     Reihenfolge wie MATLABs imageDatastore in kruemung.m.
     Schlaegt ein Video/Ordner fehl, wird mit dem naechsten weitergemacht;
     am Ende gibt es eine Zusammenfassung.
  5. Masken werden gespeichert als:
         <videoname bzw. ordnername>_sam2_masks/frame_00001.png, ...
     (uint8, 0/255; 1-basiert -> frame_00001.png entspricht MATLAB read(v,1)
      bzw. dem ersten Bild des imageDatastore)
  6. Danach kruemung_jinhan.m (Video) bzw. kruemung.m (Bilderordner) in
     MATLAB ausfuehren (laedt diese PNGs).

Einrichtung: siehe README_SAM2.md.
"""

import os
import sys
import shutil
import tempfile
import urllib.request
import tkinter as tk
from tkinter import filedialog

import numpy as np
import cv2
import matplotlib.pyplot as plt

# ============================= Konfiguration =================================
DEFAULT_PATH = r"M:\nascas2\Students\Wöhlken\2026-07-06"   # Startordner Dialog

# Modellgroesse: "auto" | "tiny" | "small" | "base_plus" | "large"
# auto -> GPU (CUDA): base_plus, sonst CPU: tiny (CPU mit large ist sehr langsam)
MODEL_SIZE = "auto"

# 1-basiert: welcher Frame wird zum Anklicken gezeigt/geprompted. Die ersten
# Frames sind oft verzerrt und fuer den Prompt ungeeignet; SAM 2 propagiert
# die Maske von hier aus automatisch in BEIDE Richtungen durch das Video.
PROMPT_FRAME = 10

# Ordner fuer die Modellgewichte (wird bei Bedarf angelegt; Download automatisch)
CHECKPOINT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "checkpoints")

JPEG_QUALITY = 95   # Qualitaet der temporaeren Frame-JPEGs
# ==============================================================================

CHECKPOINT_URLS = {
    "tiny":      "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt",
    "small":     "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_small.pt",
    "base_plus": "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_base_plus.pt",
    "large":     "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_large.pt",
}
MODEL_CFGS = {
    "tiny":      "configs/sam2.1/sam2.1_hiera_t.yaml",
    "small":     "configs/sam2.1/sam2.1_hiera_s.yaml",
    "base_plus": "configs/sam2.1/sam2.1_hiera_b+.yaml",
    "large":     "configs/sam2.1/sam2.1_hiera_l.yaml",
}


def imwrite_unicode(path, img, params=None):
    """Wie cv2.imwrite, aber sicher fuer Windows-Pfade mit Sonderzeichen
    (z.B. Umlauten) und/oder Vorwaerts-Slashes.

    cv2.imwrite() nutzt unter Windows intern eine aeltere fopen()-Route, die
    bei solchen Pfaden bei manchen OpenCV-Builds STILL fehlschlaegt (gibt nur
    False zurueck, wirft KEINE Exception) - Dateien fehlen dann kommentarlos.
    Hier wird stattdessen mit cv2.imencode() ein Byte-Array erzeugt und ueber
    Pythons eingebautes open() geschrieben (Windows-Wide-Char-API, robust).

    Wirft RuntimeError, wenn Encodierung oder Schreiben fehlschlaegt.
    """
    ext = os.path.splitext(path)[1]
    ok, buf = cv2.imencode(ext, img, params or [])
    if not ok:
        raise RuntimeError(f"cv2.imencode fehlgeschlagen fuer: {path}")
    with open(path, "wb") as f:
        f.write(buf.tobytes())
    if not os.path.isfile(path):
        raise RuntimeError(f"Datei wurde nicht geschrieben: {path}")


def ask_two_buttons(window_title, question, option_a, option_b):
    """Kleines Auswahlfenster mit 2 Buttons (wie die MATLAB-Auswahlfenster).
    option_a/option_b = (Button-Text, Rueckgabewert). Fenster schliessen = Abbruch.
    """
    choice = {"value": None}

    root = tk.Tk()
    root.title(window_title)
    root.geometry("400x110")
    root.resizable(False, False)
    tk.Label(root, text=question, font=("Segoe UI", 11, "bold")).pack(pady=8)
    row = tk.Frame(root)
    row.pack()

    def pick(value):
        choice["value"] = value
        root.destroy()

    for text, value in (option_a, option_b):
        tk.Button(row, text=text, width=18,
                  command=lambda v=value: pick(v)).pack(side="left", padx=8)
    root.mainloop()

    if choice["value"] is None:
        sys.exit("Keine Auswahl getroffen - Abbruch.")
    return choice["value"]


def select_input_type():
    """'Video (.avi)' oder 'Bilderordner (.jpg)'. Rueckgabe: 'video' | 'folder'."""
    return ask_two_buttons("Eingabe waehlen", "Was soll segmentiert werden?",
                           ("Video (.avi)", "video"),
                           ("Bilderordner (.jpg)", "folder"))


def select_batch_mode(input_type):
    """Eins oder mehrere Videos/Bilderordner? Rueckgabe: 'single' | 'batch'."""
    if input_type == "video":
        question = "Wie viele Videos segmentieren?"
        labels = ("Ein Video", "Mehrere Videos")
    else:
        question = "Wie viele Bilderordner segmentieren?"
        labels = ("Ein Bilderordner", "Mehrere Bilderordner")
    return ask_two_buttons("Anzahl waehlen", question,
                           (labels[0], "single"), (labels[1], "batch"))


def _initial_dir():
    return DEFAULT_PATH if os.path.isdir(DEFAULT_PATH) else os.path.expanduser("~")


def select_video():
    """Datei-Dialog wie uigetfile in MATLAB."""
    root = tk.Tk()
    root.withdraw()
    path = filedialog.askopenfilename(
        title="AVI-Video auswaehlen (SAM-2-Segmentierung)",
        initialdir=_initial_dir(),
        filetypes=[("AVI Video", "*.avi"), ("Alle Dateien", "*.*")],
    )
    root.destroy()
    if not path:
        sys.exit("Kein Video ausgewaehlt - Abbruch.")
    return path


def select_folder(title="Bilderordner (.jpg) auswaehlen (SAM-2-Segmentierung)"):
    """Ordner-Dialog wie uigetdir in MATLAB."""
    root = tk.Tk()
    root.withdraw()
    path = filedialog.askdirectory(title=title, initialdir=_initial_dir())
    root.destroy()
    if not path:
        sys.exit("Kein Ordner ausgewaehlt - Abbruch.")
    return path


def list_jpgs(src_dir):
    """JPG-Dateinamen eines Ordners, ALPHABETISCH sortiert (wie imageDatastore)."""
    return sorted(f for f in os.listdir(src_dir)
                  if f.lower().endswith((".jpg", ".jpeg"))
                  and os.path.isfile(os.path.join(src_dir, f)))


def make_job(input_type, path):
    """Beschreibung eines zu segmentierenden Videos/Bilderordners."""
    path = os.path.normpath(path)
    if input_type == "video":
        name = os.path.splitext(os.path.basename(path))[0]
    else:
        name = os.path.basename(path)
    # Masken landen im Nebenordner <name>_sam2_masks (neben Video bzw. Ordner)
    out_dir = os.path.normpath(os.path.join(os.path.dirname(path), f"{name}_sam2_masks"))
    return {"type": input_type, "path": path, "name": name, "out_dir": out_dir}


def collect_jobs(input_type, batch_mode):
    """Dialoge anzeigen und Liste der Jobs (Videos/Bilderordner) zurueckgeben."""
    if batch_mode == "single":
        path = select_video() if input_type == "video" else select_folder()
        return [make_job(input_type, path)]

    if input_type == "video":
        parent = os.path.normpath(select_folder(
            "Ordner mit mehreren AVI-Videos auswaehlen (SAM-2-Segmentierung)"))
        names = sorted(f for f in os.listdir(parent)
                       if f.lower().endswith(".avi")
                       and os.path.isfile(os.path.join(parent, f)))
        if not names:
            sys.exit(f"Keine .avi-Dateien gefunden in: {parent}")
    else:
        parent = os.path.normpath(select_folder(
            "Ordner mit mehreren Bilderordnern auswaehlen (SAM-2-Segmentierung)"))
        names = sorted(d for d in os.listdir(parent)
                       if os.path.isdir(os.path.join(parent, d))
                       and not d.endswith("_sam2_masks")
                       and list_jpgs(os.path.join(parent, d)))
        if not names:
            sys.exit(f"Keine Unterordner mit .jpg-Bildern gefunden in: {parent}")

    jobs = [make_job(input_type, os.path.join(parent, n)) for n in names]
    print(f"{len(jobs)} {'Videos' if input_type == 'video' else 'Bilderordner'} gefunden in {parent}:")
    for job in jobs:
        print(f"  - {job['name']}")
    return jobs


def write_prompt_frame(job, dst_path):
    """Nur den PROMPT_FRAME-ten Frame (1-basiert) nach dst_path schreiben.

    Video: Frames sequentiell bis dahin lesen (zuverlaessiger als Seek) und
    exakt so als JPEG speichern wie in extract_frames -> identisches Bild wie
    spaeter in der Segmentier-Phase. Bilderordner: das Bild wird kopiert.
    Rueckgabe: True, False wenn der Frame nicht existiert.
    """
    if job["type"] == "video":
        cap = cv2.VideoCapture(job["path"])
        if not cap.isOpened():
            raise RuntimeError(f"Video konnte nicht geoeffnet werden: {job['path']}")
        frame = None
        for _ in range(PROMPT_FRAME):
            ok, frame = cap.read()
            if not ok:
                frame = None
                break
        cap.release()
        if frame is None:
            return False
        imwrite_unicode(dst_path, frame, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
        return True

    jpgs = list_jpgs(job["path"])
    if len(jpgs) < PROMPT_FRAME:
        return False
    shutil.copy(os.path.join(job["path"], jpgs[PROMPT_FRAME - 1]), dst_path)
    return True


def extract_frames(video_path, frames_dir):
    """Alle Frames als JPEGs (00000.jpg, ...) extrahieren; SAM 2 erwartet das."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Video konnte nicht geoeffnet werden: {video_path}")
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        imwrite_unicode(
            os.path.join(frames_dir, f"{idx:05d}.jpg"),
            frame,
            [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY],
        )
        idx += 1
        if idx % 200 == 0:
            print(f"  Frames extrahiert: {idx} ...")
    cap.release()
    if idx == 0:
        raise RuntimeError("Keine Frames im Video gefunden.")
    print(f"  Frames insgesamt: {idx}")
    return idx


def copy_jpg_frames(src_dir, frames_dir):
    """JPGs eines Bilderordners ALPHABETISCH sortiert als 00000.jpg, ... in den
    Temp-Ordner kopieren (SAM 2 braucht rein numerische Dateinamen).

    Die alphabetische Sortierung entspricht der Reihenfolge von MATLABs
    imageDatastore in kruemung.m -> frame_00001.png passt zum 1. Bild dort.
    """
    jpgs = list_jpgs(src_dir)
    if not jpgs:
        raise RuntimeError(f"Keine .jpg-Dateien gefunden in: {src_dir}")
    for idx, name in enumerate(jpgs):
        shutil.copy(os.path.join(src_dir, name),
                    os.path.join(frames_dir, f"{idx:05d}.jpg"))
        if (idx + 1) % 200 == 0:
            print(f"  Bilder kopiert: {idx + 1} ...")
    print(f"  Bilder insgesamt: {len(jpgs)}")
    return len(jpgs)


def download_checkpoint(model_size):
    """Checkpoint bei Bedarf von Metas offiziellen URLs herunterladen."""
    url = CHECKPOINT_URLS[model_size]
    os.makedirs(CHECKPOINT_DIR, exist_ok=True)
    ckpt_path = os.path.join(CHECKPOINT_DIR, os.path.basename(url))
    if os.path.isfile(ckpt_path):
        return ckpt_path
    print(f"Lade SAM-2-Checkpoint ({model_size}) herunter:\n  {url}")

    def progress(blocks, block_size, total):
        done = blocks * block_size
        if total > 0:
            pct = min(100.0, done * 100.0 / total)
            print(f"\r  {pct:5.1f} %  ({done/1e6:.0f}/{total/1e6:.0f} MB)", end="")

    tmp_path = ckpt_path + ".part"
    try:
        urllib.request.urlretrieve(url, tmp_path, reporthook=progress)
    except Exception as exc:
        if os.path.isfile(tmp_path):
            os.remove(tmp_path)
        sys.exit(f"\nDownload fehlgeschlagen: {exc}\n"
                 f"Alternativ manuell herunterladen und ablegen als:\n  {ckpt_path}")
    os.replace(tmp_path, ckpt_path)
    print("\n  Download abgeschlossen.")
    return ckpt_path


def collect_prompts_interactive(predictor, state, prompt_idx, prompt_frame_rgb, label):
    """Prompt-Frame anzeigen, Klick-Prompts sammeln, Maske live anzeigen.

    prompt_idx = Frame-Index im inference_state, label = Text fuer Fenstertitel.
    Rueckgabe: (points Nx2 float32, labels N int32) mit mindestens 1 positiven
    Punkt - oder None, wenn kein positiver Punkt gesetzt wurde.
    """
    points = []   # [x, y]
    labels = []   # 1 = positiv (Draht), 0 = negativ (Hintergrund)

    fig, ax = plt.subplots(figsize=(12, 8))
    fig.canvas.manager.set_window_title(f"SAM 2 - Draht anklicken: {label}")
    ax.imshow(prompt_frame_rgb)
    ax.set_title(f"{label}\nLinksklick = Draht | Rechtsklick = Hintergrund | "
                 "'u' = rueckgaengig | Enter = fertig")
    ax.set_axis_off()

    h, w = prompt_frame_rgb.shape[:2]
    overlay = ax.imshow(np.zeros((h, w, 4), dtype=np.float32))  # Masken-Overlay
    pos_plot, = ax.plot([], [], 'g+', markersize=14, markeredgewidth=2)
    neg_plot, = ax.plot([], [], 'rx', markersize=12, markeredgewidth=2)

    def update_mask():
        """SAM 2 mit allen bisherigen Punkten aufrufen und Overlay aktualisieren."""
        if not any(l == 1 for l in labels):
            overlay.set_data(np.zeros((h, w, 4), dtype=np.float32))
            fig.canvas.draw_idle()
            return
        predictor.reset_state(state)
        _, _, mask_logits = predictor.add_new_points_or_box(
            inference_state=state,
            frame_idx=prompt_idx,
            obj_id=1,
            points=np.array(points, dtype=np.float32),
            labels=np.array(labels, dtype=np.int32),
        )
        mask = (mask_logits[0] > 0.0).squeeze().cpu().numpy()
        rgba = np.zeros((h, w, 4), dtype=np.float32)
        rgba[mask] = [0.0, 0.6, 1.0, 0.5]   # halbtransparentes Blau
        overlay.set_data(rgba)
        fig.canvas.draw_idle()

    def redraw_points():
        px = [p[0] for p, l in zip(points, labels) if l == 1]
        py = [p[1] for p, l in zip(points, labels) if l == 1]
        nx = [p[0] for p, l in zip(points, labels) if l == 0]
        ny = [p[1] for p, l in zip(points, labels) if l == 0]
        pos_plot.set_data(px, py)
        neg_plot.set_data(nx, ny)

    def on_click(event):
        if event.inaxes != ax or event.xdata is None:
            return
        if event.button == 1:
            labels.append(1)
        elif event.button == 3:
            labels.append(0)
        else:
            return
        points.append([float(event.xdata), float(event.ydata)])
        redraw_points()
        update_mask()

    def on_key(event):
        if event.key == 'enter':
            plt.close(fig)
        elif event.key == 'u' and points:
            points.pop()
            labels.pop()
            redraw_points()
            update_mask()

    fig.canvas.mpl_connect('button_press_event', on_click)
    fig.canvas.mpl_connect('key_press_event', on_key)
    plt.show()   # blockiert bis Enter / Fenster geschlossen

    if not any(l == 1 for l in labels):
        return None
    return np.array(points, dtype=np.float32), np.array(labels, dtype=np.int32)


def prompt_job(predictor, job, label):
    """PROMPT-PHASE fuer einen Job: nur den Prompt-Frame laden und klicken lassen.

    Fuer die Live-Vorschau reicht ein inference_state mit genau diesem einen
    Frame (schnell, kaum Speicher): SAM 2 berechnet die Maske auf dem Prompt-
    Frame nur aus diesem Bild, die Vorschau ist also identisch zur spaeteren
    Maske auf dem Prompt-Frame im vollen Video.

    Rueckgabe: (points, labels) oder None (kein positiver Klick).
    Wirft RuntimeError, wenn der Prompt-Frame nicht existiert.
    """
    preview_dir = tempfile.mkdtemp(prefix="sam2_prompt_")
    state = None
    try:
        frame_path = os.path.join(preview_dir, "00000.jpg")
        if not write_prompt_frame(job, frame_path):
            raise RuntimeError(f"weniger als {PROMPT_FRAME} Frames "
                               f"(PROMPT_FRAME oben im Skript anpassen)")
        prompt_rgb = cv2.cvtColor(cv2.imread(frame_path), cv2.COLOR_BGR2RGB)
        state = predictor.init_state(video_path=preview_dir)
        return collect_prompts_interactive(predictor, state, 0, prompt_rgb, label)
    finally:
        del state
        shutil.rmtree(preview_dir, ignore_errors=True)


def segment_job(predictor, job, points, point_labels):
    """SEGMENTIER-PHASE fuer einen Job: alle Frames laden, Prompt setzen,
    Maske in beide Richtungen propagieren und als PNGs speichern.

    Rueckgabe: Anzahl gespeicherter Masken. Wirft RuntimeError bei Fehlern.
    """
    out_dir = job["out_dir"]
    frames_dir = tempfile.mkdtemp(prefix="sam2_frames_")
    state = None
    try:
        if job["type"] == "video":
            print("  Extrahiere Frames ...")
            num_frames = extract_frames(job["path"], frames_dir)
        else:
            print("  Kopiere Bilder ...")
            num_frames = copy_jpg_frames(job["path"], frames_dir)
        if num_frames < PROMPT_FRAME:
            raise RuntimeError(f"Nur {num_frames} Frames, PROMPT_FRAME={PROMPT_FRAME} "
                               f"ist nicht erreichbar.")
        prompt_idx = PROMPT_FRAME - 1   # 0-basiert fuer SAM-2-API/Dateinamen

        print("  Lade Frames in SAM 2 ...")
        state = predictor.init_state(video_path=frames_dir)
        predictor.add_new_points_or_box(
            inference_state=state, frame_idx=prompt_idx, obj_id=1,
            points=points, labels=point_labels,
        )

        # --- Propagation in BEIDE Richtungen ab dem Prompt-Frame + Masken speichern ---
        os.makedirs(out_dir, exist_ok=True)
        print(f"  Propagiere Maske durch {num_frames} Frames ...")
        seen = set()
        n_saved = 0

        def save_mask(frame_idx, mask_logits):
            nonlocal n_saved
            if frame_idx in seen:
                return
            seen.add(frame_idx)
            mask = (mask_logits[0] > 0.0).squeeze().cpu().numpy().astype(np.uint8) * 255
            # 1-basiert speichern: frame_00001.png = MATLAB read(v, 1)
            imwrite_unicode(os.path.join(out_dir, f"frame_{frame_idx + 1:05d}.png"), mask)
            n_saved += 1
            if n_saved % 100 == 0:
                print(f"    {n_saved}/{num_frames} Masken gespeichert ...")

        print(f"  vorwaerts ab Frame {PROMPT_FRAME} ...")
        for frame_idx, obj_ids, mask_logits in predictor.propagate_in_video(state):
            save_mask(frame_idx, mask_logits)

        if prompt_idx > 0:
            print(f"  rueckwaerts bis Frame 1 ...")
            for frame_idx, obj_ids, mask_logits in predictor.propagate_in_video(state, reverse=True):
                save_mask(frame_idx, mask_logits)

        # Doppelte Kontrolle: tatsaechlich vorhandene Dateien zaehlen, damit ein
        # zukuenftiges stilles Fehlschlagen nicht erneut unbemerkt bliebe.
        n_on_disk = len([f for f in os.listdir(out_dir) if f.lower().endswith(".png")])
        if n_on_disk != n_saved:
            raise RuntimeError(f"{n_saved} Masken sollten geschrieben sein, aber "
                               f"{n_on_disk} PNG-Dateien liegen in\n  {out_dir}")

        print(f"  Fertig: {n_saved} Masken gespeichert in\n    {out_dir}")
        if n_saved != num_frames:
            print(f"  WARNUNG: {num_frames} Frames, aber {n_saved} Masken!")
        return n_saved
    finally:
        del state
        shutil.rmtree(frames_dir, ignore_errors=True)


def main():
    # --- Torch/SAM2 erst hier importieren (schnellere Fehlermeldung ohne Env) ---
    try:
        import torch
        from sam2.build_sam import build_sam2_video_predictor
    except ImportError as exc:
        sys.exit(f"Fehlendes Paket: {exc}\nBitte Einrichtung laut README_SAM2.md durchfuehren.")

    # --- Eingabe waehlen: Video (.avi) oder Bilderordner (.jpg), eins oder mehrere ---
    input_type = select_input_type()
    batch_mode = select_batch_mode(input_type)
    jobs = collect_jobs(input_type, batch_mode)

    # --- Device + Modellgroesse ---
    if torch.cuda.is_available():
        device = "cuda"
        model_size = MODEL_SIZE if MODEL_SIZE != "auto" else "base_plus"
        # wie im offiziellen SAM-2-Beispiel: bfloat16-Autocast + TF32 (Ampere+)
        torch.autocast("cuda", dtype=torch.bfloat16).__enter__()
        if torch.cuda.get_device_properties(0).major >= 8:
            torch.backends.cuda.matmul.allow_tf32 = True
            torch.backends.cudnn.allow_tf32 = True
    else:
        device = "cpu"
        model_size = MODEL_SIZE if MODEL_SIZE != "auto" else "tiny"
        print("Hinweis: keine CUDA-GPU gefunden -> CPU-Modus (langsamer).")
    print(f"Device: {device} | Modell: sam2.1_hiera_{model_size}")

    def free_gpu():
        if device == "cuda":
            torch.cuda.empty_cache()

    ckpt_path = download_checkpoint(model_size)
    print("Lade SAM-2-Modell ...")
    predictor = build_sam2_video_predictor(MODEL_CFGS[model_size], ckpt_path, device=device)

    # ======== PROMPT-PHASE: alle Prompt-Frames nacheinander anklicken ========
    n = len(jobs)
    prompted = []   # (job, points, labels)
    print(f"\n=== Prompt-Phase: Draht in Frame {PROMPT_FRAME} anklicken "
          f"({n} {'Video(s)' if input_type == 'video' else 'Bilderordner'}) ===")
    for i, job in enumerate(jobs, 1):
        label = f"[{i}/{n}] {job['name']} - Frame {PROMPT_FRAME}"
        print(f"{label}: bitte Draht anklicken, Enter = fertig ...")
        try:
            result = prompt_job(predictor, job, label)
        except Exception as exc:
            if batch_mode == "single":
                sys.exit(f"FEHLER ({job['name']}): {exc}")
            print(f"  FEHLER: {exc} -> wird uebersprungen.")
            continue
        finally:
            free_gpu()
        if result is None:
            if batch_mode == "single":
                sys.exit("Kein positiver Klick auf den Draht gesetzt - Abbruch.")
            print("  Kein positiver Klick -> wird uebersprungen.")
            continue
        prompted.append((job, result[0], result[1]))

    if not prompted:
        sys.exit("Keine Prompts gesetzt - nichts zu segmentieren.")

    # ======== SEGMENTIER-PHASE: alles ohne weitere Eingaben durchlaufen ========
    m = len(prompted)
    print(f"\n=== Segmentier-Phase: {m} {'Video(s)' if input_type == 'video' else 'Bilderordner'} ===")
    succeeded, failed = [], []
    for i, (job, points, point_labels) in enumerate(prompted, 1):
        print(f"\n[{i}/{m}] {job['name']}")
        try:
            n_saved = segment_job(predictor, job, points, point_labels)
            succeeded.append((job, n_saved))
        except Exception as exc:
            print(f"  FEHLER: {exc}")
            failed.append((job, str(exc)))
        finally:
            free_gpu()

    # --- Zusammenfassung ---
    skipped = [job for job in jobs if job not in [p[0] for p in prompted]]
    print("\n" + "=" * 70)
    print(f"Zusammenfassung: {len(succeeded)} erfolgreich, {len(failed)} fehlgeschlagen, "
          f"{len(skipped)} uebersprungen")
    for job, n_saved in succeeded:
        print(f"  OK      {job['name']}: {n_saved} Masken -> {job['out_dir']}")
    for job, msg in failed:
        print(f"  FEHLER  {job['name']}: {msg}")
    for job in skipped:
        print(f"  SKIP    {job['name']} (kein Prompt)")
    if input_type == "video":
        print("Jetzt kruemung_jinhan.m in MATLAB ausfuehren und das jeweilige Video waehlen.")
    else:
        print("Jetzt kruemung.m in MATLAB ausfuehren und den jeweiligen Bilderordner waehlen.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
