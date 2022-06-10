@include "bg_core.awk"

function addFile(filename,basename) {
	arrayCreate2(nodes, basename);
	arrayCreate2(nodes[basename], "deps");
	nodes[basename]["filename"] = filename;

	if (basename ~ /[.]c$/) {
		if (filename ~ /^lib\//) {
			nodes[basename]["objName"] = "$(OBJ)"gensub(/[.]c$/,".o","g",basename);
			nodes[basename]["type"] = "c.lib";
		}
		else {
			nodes[basename]["objName"] = "$(OBJ)"gensub(/[.]c$/,".o","g" ,basename);
			nodes[basename]["soName"]  = "$(BIN)"gensub(/[.]c$/,".so","g",basename);
			nodes[basename]["type"] = "c.so";
		}
	} else if (basename ~ /[.]h$/) {
		nodes[basename]["type"] = "h.lib";
	} else {
		printf("error: unknown file type for '%s'\n", filename);
	}
}

function getDeps(seendeps, basename           ,dep) {
	# if its not in nodes, its a system (or bash) header that we dont decend into
	if (!(basename in nodes))
		return;

	# add all the direct deps, descending into them recursively
	for (dep in nodes[basename]["deps"]) {
		if (!(dep in seendeps)) {
			seendeps[dep]=""
			getDeps(seendeps, dep);
		}
	}
}

# $(BIN)bgCore.so : $(OBJ)bgCore.o $(LIBMODULES)
# 	$(SHOBJ_LD) $(SHOBJ_LDFLAGS) $(SHOBJ_XLDFLAGS) -o $@ $< $(LIBMODULES)
function writeSOBuildRule(basename) {
	printf("%s : %s $(LIBMODULES)\n\t$(SHOBJ_LD) $(SHOBJ_LDFLAGS) $(SHOBJ_XLDFLAGS) -o $@ $< $(LIBMODULES)\n",
		nodes[file]["soName"],
		nodes[file]["objName"]);
}

# $(OBJ)bgCore.o : bgCore.c
# 	$(SHOBJ_CC) $(SHOBJ_CFLAGS) $(CCFLAGS) $(INC) -c -o $@ $<
function writeDepRule(basename                ,seendeps) {
	arrayCreate(seendeps);
	getDeps(seendeps, file);
	printf("%-*s : %s %s\n\t$(SHOBJ_CC) $(SHOBJ_CFLAGS) $(CCFLAGS) $(INC) -c -o $@ $<\n",
		targetMaxWidth, nodes[file]["objName"],
		basename,
		arrayJoini(seendeps," "));
}



BEGIN {
	arrayCreate(nodes);
	arrayCreate(targets);
}

BEGINFILE {
	basename = gensub(/^.*\//,"","g", FILENAME);
	addFile(FILENAME, basename);
}

$1 == "#include" && $2 ~ /^"/ {
	headername = gensub(/^["]|["]$/,"","g",$2)
	nodes[basename]["deps"][headername] = ""
}

END {
	#printfVars("nodes")

	targetMaxWidth = 0;
	for (file in nodes) if (nodes[file]["type"]~"^c")
		targetMaxWidth = max(targetMaxWidth, length(nodes[file]["objName"]))

	PROCINFO["sorted_in"] = "@ind_str_asc";

	for (file in nodes) if (nodes[file]["type"]~"^c.so") {
		writeSOBuildRule(file);
		writeDepRule(file);
	}

	for (file in nodes) if (nodes[file]["type"]~"^c.lib") {
		writeDepRule(file)
	}
}
