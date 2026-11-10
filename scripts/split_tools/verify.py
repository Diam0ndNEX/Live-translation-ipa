import subprocess,collections,sys,re
from pathlib import Path
def verify(src, parts):
    orig=subprocess.run(["git","show",f"HEAD:{src}"],capture_output=True,text=True).stdout.split("\n")
    new=Path(src).read_text().split("\n")
    for p in parts: new+=Path(p).read_text().split("\n")
    A,B=collections.Counter(orig),collections.Counter(new)
    miss=A-B; extra=B-A
    def norm(l): 
        l=re.sub(r"\bprivate\(set\) ","",l); l=re.sub(r"\b(private|fileprivate) ","",l); return l
    mn=collections.Counter(norm(l) for l in miss.elements())
    en=collections.Counter(norm(l) for l in extra.elements())
    bad_missing=mn-en; bad_extra=en-mn
    ok_extra=[l for l in bad_extra.elements() if l.strip()=="" or l.startswith("import ") or l.startswith("extension ") or l.strip()=="}"]
    real_extra=[l for l in bad_extra.elements() if l not in ok_extra]
    print(src,"| access-only changes:",sum(miss.values()),"| unexplained missing:",list(bad_missing.elements())[:5],"| unexplained extra:",real_extra[:5])
if __name__=="__main__":
    verify(sys.argv[1], sys.argv[2:])
