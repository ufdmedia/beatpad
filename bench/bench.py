#!/usr/bin/env python3
"""Measure deterministic live tracking using user-supplied audio paths.

Relative audio paths are resolved against the manifest directory. Requires ffmpeg
for MP3 decoding and splice construction. No audio or logs are saved outside the
ignored cache; BEATPAD_BIN can select a comparison executable.
"""
import argparse, json, pathlib, sys, subprocess, statistics, os, tempfile, math

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tracks', type=pathlib.Path, required=True)
parser.add_argument('mode', choices=('tune', 'holdout', 'all', 'splice'))
args = parser.parse_args()
manifest = json.loads(args.tracks.read_text())
base = args.tracks.resolve().parent
root = pathlib.Path(__file__).resolve().parent.parent
binary = os.environ.get('BEATPAD_BIN', str(root / 'beatpad'))
cache = root / 'bench' / '.cache'
cache.mkdir(parents=True, exist_ok=True)
def track(path):
    path = pathlib.Path(path).expanduser()
    return path if path.is_absolute() else base / path

if args.mode == 'splice':
    cases = manifest['splice']
    length = manifest.get('splice_length', 60)
    if not cases:
        sys.exit('no splice cases')
    splice_cache = tempfile.TemporaryDirectory(prefix='splice-', dir=cache)
    directory = pathlib.Path(splice_cache.name)
    print(f'splice ({len(cases)} tracks); 48 kHz hard cuts; jitter ±200 us; post scores from splice + 10 s', flush=True)
    print('| Splice | first bpm | second bpm | wrong s | re-acquire s | recall % | precision % | mean ms | pass |', flush=True)
    print('|' + '---|' * 9, flush=True)
    passed = 0
    for index, case in enumerate(cases):
        name = case['name']
        first, second = track(case['first']), track(case['second'])
        first_start, start = case.get('first_start', 0), case['second_start']
        cut = case.get('first_length', length)
        audio = directory / f'splice-{index + 1}.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(first), '-i', str(second),
                        '-filter_complex', f'[0:a]aresample=48000,atrim=start_sample={round(first_start*48000)}:end_sample={round((first_start+cut)*48000)},asetpts=PTS-STARTPTS,aformat=channel_layouts=stereo[a];[1:a]aresample=48000,atrim=start_sample={round(start*48000)}:end_sample={round((start+length)*48000)},asetpts=PTS-STARTPTS,aformat=channel_layouts=stereo[b];[a][b]concat=n=2:v=0:a=1[out]',
                        '-map', '[out]', '-c:a', 'pcm_f32le', str(audio)], check=True)
        result = subprocess.run([binary, '--simulate-live', str(audio), '--splice-at', str(cut)], capture_output=True, text=True, check=True)
        lines = [s for s in result.stdout.splitlines() if s.startswith('RESULT ')]
        if len(lines) != 1: sys.exit(f'missing RESULT: {name}\n{result.stdout}\n{result.stderr}')
        d = {k:float(v) for k,v in (x.split('=',1) for x in lines[0].split()[1:])}
        ok = d['wrong_s'] <= 3 and d['reacquire_s'] <= 8 and d['recall'] >= 85 and d['precision'] >= 85
        passed += ok
        print('| '+name+' | '+' | '.join(f'{d[k]:.2f}' for k in ['first_bpm','file_bpm','wrong_s','reacquire_s','recall','precision','mean_ms'])+' | '+('PASS' if ok else 'MISS')+' |', flush=True)
    print(f'ACCEPTANCE splice: {"PASS" if passed == len(cases) else "FAIL"} ({passed}/{len(cases)})', flush=True)
    splice_cache.cleanup()
    sys.exit(0 if passed == len(cases) else 1)
keys = ['file_bpm','live_bpm','agreement','relocks','lock_s','flips','recall','precision','mean_ms','p90_ms']
all_accepted = True
for split in (['tune','holdout'] if args.mode=='all' else [args.mode]):
    paths = [track(path) for path in manifest[split]]
    if not paths:
        sys.exit(f'no tracks in {split}')
    rows=[]
    print(f'{split} ({len(paths)} tracks); jitter ±200 us; agreement uses locked time after 15 s', flush=True)
    print('| Track | file bpm | live bpm | agree % | relocks | lock s | flips | recall % | precision % | mean ms | p90 ms | pass |',flush=True)
    print('|'+'---|'*12,flush=True)
    for path in paths:
        label = f'track-{len(rows) + 1}'
        with tempfile.TemporaryDirectory(dir=cache,prefix='bench-') as temp:
            audio=path
            if path.suffix.lower()=='.mp3':
                audio=pathlib.Path(temp)/'audio.wav'
                subprocess.run(['ffmpeg','-v','error','-y','-i',str(path),str(audio)],check=True)
            result=subprocess.run([binary,'--simulate-live',str(audio)],capture_output=True,text=True,check=True)
        lines=[s for s in result.stdout.splitlines() if s.startswith('RESULT ')]
        if len(lines)!=1: sys.exit(f'missing RESULT: {label}\n{result.stdout}\n{result.stderr}')
        d={k:float(v) for k,v in (x.split('=',1) for x in lines[0].split()[1:])}
        passed=d['relocks']<=2 and d['agreement']>=80 and d['recall']>=85 and d['precision']>=85 and d['mean_ms']<=15
        if path.suffix.lower()=='.mp3': passed &= d['recall']>=90 and d['precision']>=95
        rows.append((d,passed))
        print('| '+label+' | '+' | '.join(f'{d[k]:.2f}' for k in keys)+' | '+('PASS' if passed else 'MISS')+' |',flush=True)
    med={k:statistics.median(d[k] for d,_ in rows) for k in keys}
    print('| MEDIAN | '+' | '.join(f'{med[k]:.2f}' for k in keys)+' | |',flush=True)
    agreement=sum(d['agreement']>=80 for d,_ in rows)
    print(f'Per-track passes: {sum(p for _,p in rows)}/{len(rows)}; agreement >=80%: {agreement}/{len(rows)} ({100*agreement/len(rows):.2f}%)',flush=True)
    accepted=(sum(p for _,p in rows)>=math.ceil(len(rows)*11/21) and med['recall']>=90 and med['precision']>=92 and all(d['recall']>=90 and d['precision']>=95 for path,(d,_) in zip(paths, rows) if path.suffix.lower()=='.mp3')) if split=='tune' else (med['recall']>=84.6 and med['precision']>=78.6)
    print(f'ACCEPTANCE {split}: {"PASS" if accepted else "FAIL"}',flush=True)
    all_accepted &= accepted
sys.exit(0 if all_accepted else 1)
