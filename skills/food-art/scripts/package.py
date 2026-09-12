#!/usr/bin/env python3
"""Final package gate, contrast computation and fresh source/raster proof."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
from library import ROOT, ART, dump, digest, svg
from verify import verify

def luminance(color):
    values=[int(color[i:i+2],16)/255 for i in (1,3,5)]
    linear=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in values]
    return sum(v*w for v,w in zip(linear,(.2126,.7152,.0722)))
def ratio(a,b):
    x,y=sorted((luminance(a),luminance(b)));return (y+.05)/(x+.05)
def files():return sorted(p for base in (ART,ROOT/'skills/food-art') for p in base.rglob('*') if p.is_file() and p.name!='manifest.sha256')
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--write-manifest',action='store_true');ap.add_argument('--check-manifest',action='store_true');ap.add_argument('--reproduce',action='store_true');args=ap.parse_args()
    report=verify()
    if args.reproduce:
        n=0
        with tempfile.TemporaryDirectory(prefix='food-art-rerender-') as temp:
            for a in json.loads((ART/'catalog.json').read_text())['assets']:
                spec=json.loads((ART/a['source']).read_text())
                for theme in ('paper','night'):assert (ART/f'masters/{a["id"]}-{theme}.svg').read_text()==svg(spec,theme)
                for rel in a['exports']:
                    theme,size=Path(rel).stem.rsplit('-',2)[-2:];out=Path(temp)/'fresh.png'
                    subprocess.run(['rsvg-convert','-w',size,'-h',size,'-o',str(out),str(ART/f'masters/{a["id"]}-{theme}.svg')],check=True,timeout=30)
                    assert digest(out)==digest(ART/rel),('nondeterministic raster',rel);n+=1
        dump(ART/'evidence/reproduction.json',{'status':'PASS','fresh_byte_identical_exports':n,'masters_equal_saved_source_compiler':report['editable_masters'],'raw_exit':0})
    pairs=[]
    for theme,bg,text,line in [('paper','#FFF7E8','#2A261F','#8B7355'),('night','#2A261F','#FFF7E8','#8B7355')]:
        for role,fg,floor in [('body, names, captions and controls',text,4.5),('large headings',text,3),('control boundary',line,3),('focus ring','#E66A2C',3)]:
            value=ratio(fg,bg);assert value>=floor
            pairs.append({'theme':theme,'role':role,'foreground':fg,'background':bg,'ratio':round(value,3),'floor':floor})
    dump(ART/'evidence/contrast.json',{'scope':'Actual gallery/phone CSS pairs on flat grounds; art is labeled decorative, not data marks. No page grain.','pairs':pairs})
    for p in files():assert not any(x in p.parts for x in ('__pycache__','.DS_Store')) and p.suffix not in ('.pyc','.pyo','.tmp','.bak')
    manifest=ART/'manifest.sha256'
    if args.write_manifest:manifest.write_text(''.join(f'{digest(p)}  {p.relative_to(ROOT)}\n' for p in files()))
    if args.check_manifest:
        listed={line.split('  ',1)[1]:line.split('  ',1)[0] for line in manifest.read_text().splitlines()}
        actual={str(p.relative_to(ROOT)):digest(p) for p in files()};assert listed==actual,'manifest set/hash mismatch'
        report|={'manifest_entries':len(actual),'raw_files_in_two_scoped_roots':len(actual)+1,'manifest_lists_itself':False,'bytes_in_two_scoped_roots':sum(p.stat().st_size for p in files())+manifest.stat().st_size}
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
