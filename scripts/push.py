import os, sys

def Exec(command) -> None:
	print(command)
	os.system(command)

if len(sys.argv) != 2:
	print("Please provide a commit message")
	sys.exit()

Exec("git add .")
Exec("git add -u")
Exec("git commit -m \"" + sys.argv[1] + "\"")
Exec("git push origin main")
