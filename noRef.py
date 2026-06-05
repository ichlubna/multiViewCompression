import sys
import pyiqa

liqe = pyiqa.create_metric('liqe_mix', as_loss=False)
qualiclip = pyiqa.create_metric('qualiclip', as_loss=False)
arniqa = pyiqa.create_metric('arniqa', as_loss=False)
print(liqe(sys.argv[1]).item(), qualiclip(sys.argv[1]).item(), arniqa(sys.argv[1]).item())
