extends SceneTree
var differences := []
func _initialize() -> void:
	var a=FileAccess.open("res://artifacts/citadel-runtime-integration/candidate-recipe-27/source.bin",FileAccess.READ).get_var(false)
	var b=FileAccess.open("res://artifacts/citadel-runtime-integration/candidate-recipe-28/source.bin",FileAccess.READ).get_var(false)
	compare(a,b,"")
	var f=FileAccess.open(OS.get_environment("SOURCE_DIFF_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"passed":true,"checks":{"comparison_completed":true},"differences":differences},"\t"));f.close()
	quit()
func compare(a,b,path:String)->void:
	if differences.size()>=30:return
	if typeof(a)!=typeof(b):differences.append({"path":path,"type":true});return
	if a is Dictionary:
		for k in a:
			if not b.has(k):differences.append({"path":path+"/"+str(k),"missing":true})
			else:compare(a[k],b[k],path+"/"+str(k))
		for k in b:
			if not a.has(k):differences.append({"path":path+"/"+str(k),"added":true})
	elif a is Array:
		if a.size()!=b.size():differences.append({"path":path,"sizes":[a.size(),b.size()]});return
		for i in a.size():compare(a[i],b[i],path+"/"+str(i))
	elif a!=b:differences.append({"path":path,"a":str(a).left(180),"b":str(b).left(180)})

