import re,sys
from pathlib import Path
def sigcheck(files):
    txt={f:Path(f).read_text().split("\n") for f in files}
    privtypes=set()
    for f,L in txt.items():
        for l in L:
            m=re.match(r"^\s{4}(?:private|fileprivate)\s+(?:struct|enum|class|actor|typealias)\s+(\w+)",l)
            if m: privtypes.add(m.group(1))
            m=re.match(r"^(?:private|fileprivate)\s+(?:struct|enum|class|actor|typealias)\s+(\w+)",l)
            if m: privtypes.add(m.group(1))
    bad=[]
    for f,L in txt.items():
        for i,l in enumerate(L):
            if re.match(r"^\s{4}(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|static|nonisolated|lazy|class|mutating)\s+)*(?:func|var|let)\s+\w+",l) and not re.search(r"\bprivate\b|\bfileprivate\b",l.split("{")[0].split("=")[0]):
                head=l
                j=i
                while head.count("(")>head.count(")") and j<i+6: j+=1; head+=L[j]
                head=head.split("{")[0] if "func" in head else head.split("=")[0]
                for t in privtypes:
                    if re.search(r"\b"+t+r"\b",head): bad.append((f,i+1,t,l.strip()[:80]))
    return bad
if __name__=="__main__":
    for b in sigcheck(sys.argv[1:]): print(b)
    print("sigcheck done")
