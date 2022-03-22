@include "bg_core.awk"

# Library
# This awk library implements parsing bash code into nodes and edges that can be displayed in cytoscape. The model it builds has
# general applications besides visualization.
#
# Input:
# All the cmd.script.bash and lib.script.bash files of a set of projects (typically the set of a vinstalled sandbox) should be
# streamed as stdin input to this script. For each script both the scriptContent and the output from "bashParse --parse-tree-print $filePath"
# should be streamed.
#
#  foreach <file>
#    cat <file>
#    bashParse --parse-tree-print <file>
#
# Data model
# the nodes[] is a map of all found nodes.
# The key of nodes is "<type>:<id>" so that each <type> has its own namespace to avoid collisions
# Attributes of Nodes:
#      ["id"]   : the fully qualified unique name of the node
#      ["key"]  : <type>:<id> used as the keys in nodes[]
#      ["type"] : project|file|func|fileGroup
#                 the type determines the type of graph node
#      ["subType"] : varies by type
#              file -> <assetType>
#              func -> |alias   (empty string is a normal function)
#              fileGroup -> folder|prefix
#      ["label"] : the short display name for the node.
#      ["parent"]: the key of the parent node or "" if its top level
#
# 66 basename
#  8 driver
# 1151 id
# 1151 key
# 1151 label
# 863 lineno
# 1151 parent
# 66 project
# 1151 subType
# 86 target
# 1151 type
#
# Ondemand Stubs:
# The bg-core style scripts use a pattern for some libraries that allows them to be automatically lazy sourced (aka imported aka
# loaded) only if they are used.
# Stub functions for the entrypoint functions are placed in core libraries (typically bg_coreLibsMisc.sh) so that they are always
# available to a script that sources /usr/lib/bg_core.sh. Those stub functions import the library that contains the real function
# by the same name and then re-calls itself. The real function ovrewrites the stub in memory when its loaded so re-calling itself
# redirects to the real function.
#
# This pattern produces two functions by the same name but from diferent libraries so a call to that function name is ambiguous
# from a static analysis POV WRT to which of the two functions will be called. For our puprposes, any call to that name in normal
# code will produce a dependency to the stub version and the stub version code will have a dependency on the real function library.
# At runtime, only the first call will invoke the stub and all subsequent calls will invoke the real function directly but that
# does not matter in a static analysis. (at least for what we are modeling now)
#
# The <subType> attribute of the stub function will be "stub" To avoid conflicts of the nodes[] key, the real function will have
# "-ondemandStubTarget" appended to the key.
#
# For any <functionName>, you can lookup the canoical version at "func:<functionName>".
# If nodes["func:<functionName>"]["subType"]=="ondemandStub" then nodes["func:<functionName>-ondemandStubTarget"] will lead to the real implementation







# create the node if it does not already exist
# nodes is a map of arrays. The elements are arrays that represent the attributes of the node
# The keys are "<keyType>:<id>"
#    project:<projectName>
#    file:<file_ID>   (file_ID is relative path starting with projectFolder)
#    fileGroup:<groupName>  (groups are typically sub-folders but can also be common prefix, etc...)
#    func:<functionName>
function createNode(id, type, subType, parent                     ,key) {
	if (!id) assert("id can not be empty. type="type" subType="subType"  parent="parent)
	key=type":"id
	# we can not assert that parent exits because somtimes we dont crate the parent first (maybe driverFiles?)
	#if (parent && !(parent in nodes)) assert("createNode(id="id", type="type", subType="subType", parent="parent"): parent node does not exist")
	if (!(key in nodes)) {
		arrayCreate2(nodes, key)
		nodes[key]["id"]=id
		nodes[key]["key"]=key
		nodes[key]["type"]=type
		nodes[key]["subType"]=subType
		nodes[key]["parent"]=parent
		nodes[key]["label"]=gensub(/^([^:]*:)?(.*\/)?/,"","g",key)
		arrayCreate2(nodes[key],"classes")
	} else {

		# this handles the conflict between a ondemandStub function and its real function with the same name but different file( aka parent)
		# we dont know whether the stub or real function version will be parsed first, but as long as the stub is given the subType=="ondemandStub"
		# this block will work in either order.
		# There is an issue that if the real function parses first and the stub function source is not marked with # ondemandStub,
		# there will be a conflict error because we create the stub function without the subType during the source scan and dont
		# realize its a stub until the parserOutput scan.
		# TODO: consider not asserting conlicts in this function but instaed store them in an alternate array (nodesConflicts[])
		#       then in the END{} try to resolve the conflicts and assert any that can not be resolved.
		if (type=="func" && nodes[key]["parent"]!=parent && (nodes[key]["subType"]=="ondemandStub" || subType=="ondemandStub")) {
			if (nodes[key]["subType"]=="ondemandStub") {
				return createNode(id"-ondemandStub", type, subType, parent)
			} else {
				arrayCopy2(nodes[key],nodes,key"-ondemandStub")
				delete nodes[key]
				return createNode(id, type, subType, parent)
			}
		}

		if (nodes[key]["subType"] != subType) {
			if (subType=="ondemandStub")
				nodes[key]["subType"]=subType;
			else if (nodes[key]["subType"]!="ondemandStub")
				assert("logical error: createNode(id='"id"', type='"type"', subType='"subType"', subType='"subType"'): node was already created with a different subType '"nodes[key]["subType"]"'")
		}
		if (nodes[key]["parent"] != parent)
			assert("logical error: createNode(id='"id"', type='"type"', subType='"subType"', parent='"parent"'): node was already created with a different parent '"nodes[key]["parent"]"'")
	}
	return key
}

# usage: <funcKey> registerCmdFunc(cmdName, funcName)
# functions defined in cmds do not need to be unique. The out of band sytem uses this fact to have callback functions defined in
# cmds that are automatically invoked in various circumstances as needed.
# The nodes[] array requires that each unique node has a unique key so that they do not collide and overwrite each other.
# When we come accross a function definition while parsing a cmd.script.bash, we call this function to register it and get the
# unique key that we can use to add the function nose to nodes.
function registerCmdFunc(cmdName, funcName                     ,newName) {
	newName=cmdName":"funcName
	if (!(funcName in cmdFunctions)) {
		arrayCreate2(cmdFunctions, funcName)
	}
	cmdFunctions[funcName][newName]=""
	return newName
}


BEGIN {
	inputMode=""
	arrayCreate(nodes)
	arrayCreate(edges)
	arrayCreate(cmdFunctions)

	# the driver library pattern produces multiple library files with the same functions names. Currently, we hard code this
	# driverFiles structure but eventually we will detect and build it during the scan.
	driverFiles["bg-dev/lib/bg_debuggerCUIWin.sh"]="bg-dev/lib/bg_debugger.sh"
	driverFiles["bg-dev/lib/bg_debugger_integrated.sh"]="bg-dev/lib/bg_debugger.sh"
	driverFiles["bg-dev/lib/bg_debugger_remote.sh"]="bg-dev/lib/bg_debugger.sh"

	driverFiles["bg-core/lib/bg_progressCntxImplArray.sh"]="bg-core/lib/bg_cuiProgress.sh"
	driverFiles["bg-core/lib/bg_progressOneline.sh"]="bg-core/lib/bg_cuiProgress.sh"
	driverFiles["bg-core/lib/bg_progressTermTitle.sh"]="bg-core/lib/bg_cuiProgress.sh"
	driverFiles["bg-core/lib/bg_progressCntxImplTmpFile.sh"]="bg-core/lib/bg_cuiProgress.sh"
	driverFiles["bg-core/lib/bg_progressStatusline.sh"]="bg-core/lib/bg_cuiProgress.sh"

	createNode("foriegn",      "project", "", "")
	createNode("files",        "fileGroup", "virtual", "project:foriegn")
	createNode("builtins",     "fileGroup", "virtual", "project:foriegn")
	createNode("objectCalls",  "fileGroup", "virtual", "project:foriegn")
	createNode("dynamicCalls", "fileGroup", "virtual", "project:foriegn")
	createNode("unclassified", "fileGroup", "virtual", "project:foriegn")
}

# the script that feeds us streams the script contents and then the parser output for that script
$0=="?!?"          {inputMode="parserOutput"}
$1=="[AssetInfo]"  {inputMode="scriptContent"}


##################################################################################################################################
# start of a inputMode=="scriptContent" section.

# [AssetInfo] is the manifest record for this file inserted just before the file contents is streamed.
inputMode=="scriptContent" && $1=="[AssetInfo]" {processAssetInfo($2,$3,$4,pathGetCanonStr($5))}
function processAssetInfo(pkgName,assetType,assetName,filePath                   ,i,folders,fParts,fileGroupPath,parent) {
	file_project=$2
	file_ID=gensub("(^.*/|^)"file_project"/",file_project"/","g", filePath);
	file_basename=gensub("^.*/","","g",filePath)

	# create the project node if its not already created
	createNode(file_project, "project", "", "")

	# create folder fileGroups if any
	folders=gensub("[/]?"file_basename"$","","g",file_ID)
	split(folders,fParts, "/")
	arrayShift(fParts); # shift off the project
	parent="project:"file_project
	fileGroupPath=file_project
	for (i in fParts) {
		fileGroupPath=fileGroupPath"/"fParts[i]
		createNode(fileGroupPath, "fileGroup", "folder", parent)
		parent="fileGroup:"fileGroupPath
	}

	# now create a node for the script file
	createNode(file_ID, "file", assetType , parent);
	nodes["file:"file_ID]["basename"]=file_basename;
	nodes["file:"file_ID]["project"]=file_project;

	# record if this is a driver file because they have functions by the same name
	if (file_ID in driverFiles) {
		nodes["file:"file_ID]["driver"]=driverFiles[file_ID]
	}
}

{functionDeclCode=""}

# a function alias line
# Function aliases get their own node, but by default, we skip them and lump them in with the taget function.
# aliasesMap[alias]=target makes it easy to link to the target function instead of the alias node.
# alternatively, we could make a functionGroup node but its possible that an alias is in a different file (that should be a lint error, I think )
# function completeAwkDataColumnNames()  { awkData_bcColumnNames [opts...] "$@"; } [# alias|depreciated|obsolete]
inputMode=="scriptContent" && /^function[[:space:]][_a-zA-Z].*[{][[:space:]]+[^}]*[[:space:]]+"[$]@"[[:space:]]*;[[:space:]]+[}]/ { processFunctionAlias(); }
function processFunctionAlias(                          aliasName,target) {
	functionDeclCode="alias"
	aliasName=$2; sub("[(][)]$","",aliasName)
	target=$0; sub("^.*[{][ \t]*","",target); sub(" .*$","",target)

	aliasesMap[aliasName]=target

	# we don't create the target node at this point because we cant be sure of the parent so in the END{} we can iterate aliasesMap
	# and fix up the target nodes with the alias info

	# functions defined in commands often have the same names as in other commands but that is ok because they are also not targets
	# of dependencies. For example, oob_printBashCompletion is in all commands as a callback. Even though its called from a core
	# library, its not a dependency.
	if (nodes["file:"file_ID]["subType"] ~ /^cmd/)
		aliasName=registerCmdFunc(nodes["file:"file_ID]["basename"], aliasName)

	# the "functionAlias" nodes will be skipped by default (maybe there is not option to change that)
	createNode(aliasName, "func", "alias", "file:"file_ID)
	nodes["func:"aliasName]["target"] = target;
	nodes["func:"aliasName]["classes"]["alias"]=""
	if (tolower($0) ~ /#[[:space:]]+depreciated|obsolete/)
		nodes["func:"aliasName]["classes"]["depreciated"]=""
}


# a function start line
#inputMode=="scriptContent" && /^function[[:space:]][_a-zA-Z][_:[:alnum:]]*[(][)][ \t]*[{]?[ \t]*(#.*)?$/ { processFunctionStart($2); }
inputMode=="scriptContent" && /^function[[:space:]]/ { if (!functionDeclCode) processFunctionStart($2); }
function processFunctionStart(funcName                              ,parentFile,subType) {
	functionDeclCode=appendStr(functionDeclCode, "normal", " ") # this should be removed after we know we are not going back -- see block below (search functionDeclCode)
	funcName=gensub(/[(][)]$/,"","g",funcName);

	# see "OnDemand Stub" section of this Library's manpage
	# We detect ondemandStub functions two ways. Here we only detect it if the function line has an EOL comment
	# In the bashParser output (immediately following the script contexts ) if a function calls import and itself it is considered
	# to be a stub. Create node will handle the duplicate call if one of them has the subType ondemandStub
	if ($0 ~ "# ondemandStub") {
		subType="ondemandStub"
	}

	# if we are in a driverFile, we attribute its functions to the library file that loads it. Actually only the API functions
	# should be but initially we dont model that. The reason we need to do this is that driverFiles have duplicate function names
	parentFile=file_ID;
	if ("driver" in nodes["file:"file_ID]) {
		parentFile=nodes["file:"file_ID]["driver"];
	}

	# functions defined in commands often have the same names as in other commands but that is ok because they are also not targets
	# of dependencies. For example, oob_printBashCompletion is in all commands as a callback. Even though its called from a core
	# library, its not a dependency.
	if (nodes["file:"file_ID]["subType"] ~ /^cmd/)
		funcName=registerCmdFunc(nodes["file:"file_ID]["basename"], funcName)

	createNode(funcName, "func", subType, "file:"parentFile);
	function_ID=funcName;
}

# I put this block in to see what functions were being ignored. I found that there were a few one line function definitions that
# were not aliases. I changed the normal function block to hit all instead of trying not to hit alias  and used functionDeclCode
# to not process alias twice. Once it is confirmed we are not going back we can remove this block
# /^function[[:space:]]/ {
# 	switch (functionDeclCode) {
# 		case "alias": break;
# 		case "normal": break;
# 		case "alias normal": bgtraceVars2("both alias and normal function blocks hit for this line","","$0",$0);
# 		case "":             bgtraceVars2("nither alias nor normal function blocks hit for this line","","$0",$0);
# 	}
# }

# a function end line
inputMode=="scriptContent" && /^[}][ \t]*$/ { processFunctionEnd($2); }
function processFunctionEnd(funcName) {
	function_ID="";
}


# global import line
# note that this only captures global imports. conditional imports which are typically in functions are not captured here
inputMode=="scriptContent" && /^import .*;[$]L1(;[$]L2)?/ { processImport($2); }
function processImport(scriptName                   ,parts, scriptProject) {
	split(pathGetCanonStr(manifestImportLookup("-o$1%20$4", scriptName)), parts);
	scriptProject=parts[1];
	scriptName=gensub("^(.*/|)"scriptProject"/",scriptProject"/","g",parts[2]);

	# record the import in the file_ID
	nodes["file:"file_ID]["imports"]["file:"scriptName]=""
}

# conditional import line
# conditional imports are typically in functions or have a '[ ... ] && ' preceeding them
inputMode=="scriptContent" && /^[^#]+import .*;[$]L1(;[$]L2)?/ { processConditionalImport(); }
function processConditionalImport(                      scriptName) {
	# TODO: these conditional imports somtimes have more complicated calls than just a simple libary name
	scriptName=gensub(/(^.*import)|(;[$]L1.*$)/,"","g",$0)
	# split(pathGetCanonStr(manifestImportLookup("-o$1%20$4", scriptName)), parts);
	# scriptProject=parts[1];
	# scriptName=gensub("^(.*/|)"scriptProject"/",scriptProject"/","g",parts[2]);
	importsConditionalMap["file:"file_ID]="file:"scriptName

	# if we are in a function, function_ID will exist, otherwise we are in the global scope
	nodes[( function_ID) ? ("func:"function_ID) : ("file:"file_ID) ]["importsConditional"]["file:"scriptName]
}


##################################################################################################################################
# start of a inputMode=="parserOutput" section.


# usage: <key> registerEXCMDnode(excmd,context)
# The bashParser lists every token in the source that will be executed in EXCMD: lines of its output.
# As we read them, we pass them through this function which will create a node for them if required. The key of the node is returned
# to the caller.
# Params:
#    <excmd> : a executatble token or phrase as identified by the bashParser
#    <context> : for the case of excmd which are functions defined in cmd.script.bash files, we need to know the name of the command.
#                if <context> is not empty, it is <scriptName>:<callingFn> that is invoking <excmd>
# Return Value:
#    <key>  : the key of the nodes[<key>] entry representing this excmd
function registerEXCMDnode(excmd,context                              ,retKey,line) {
	# Sometimes the parser does not descend into a $(<cmd> ...) phrase
	# For example: '$(getUserCmpApp)' -> 'EXCMD: getUserCmpApp' but '[ ...] && $(getUserCmpApp)' -> 'EXCMD: $(getUserCmpApp)'
	if (excmd ~ /^[[:space:]]*[$][(](.*)[)]$/)
		excmd = gensub(/^[[:space:]]*[$][(][[:space:]]*|([[:space:]](.*))?[)]$/,"","g",excmd)

	# this is the most typical case. excmd is a bash function that exists in some library
	if ("func:"excmd in nodes)
		return "func:"excmd

	# if <context> is given and contains a ':', we are processing a call made inside a cms.script.bash file and this block detects
	# a call made to a function defined inside that cmd.script.bash file
	if ((context~/[:]/) && ("func:"gensub(/:.*$/,"","g",context)":"excmd in nodes))
		return "func:"gensub(/:.*$/,"","g",context)":"excmd

	# functions in cmd.script.bash files are qualified with the script name. This handles the case of a library code calling a
	# callback defined inside the cmd.script.bash file that invoked it. These typically only call the callback if it exists and
	# TODO: the cmdFunctions[] array maps this call to multiple cmd.script.bash files. Should we make it so that this EXCMD call
	#       creates edges to each of them?
	if (excmd in cmdFunctions) {
		# TODO: we are ignoring these callback calls now but we could create a type='func'  subType='callback' node
		return ""
	}

	# object syntax -- remove everthing except the first token
	if (excmd ~ /^[$][^{].*[.:=[]/) {
		# a static call:  $Plugin::get
		if (excmd ~ /^[$][[:alnum:]]\+::[_:[:alnum:]]*/) {
			retKey=gensub(/^[$]/,"","g",excmd)
			# its valid to call a static method using $static or an obj ref like $myObj::<statcMethod> in which case this block
			# wont trigger and we fall through to the generic externalCmd block below
			if ("func:static::"retKey in nodes)
				return "func:static::"retKey
		}
		return createNode(sanitizeEXCMD(excmd), "externalCmd", "objectCall", "fileGroup:objectCalls");
	}

	# we already did the object calls we understand so now those that start with $ are some sort of dynamic call
	if (excmd ~ /^[[:space:]]*"?[$]/) {
		return createNode(sanitizeEXCMD(excmd), "externalCmd", "dynamicCall", "fileGroup:dynamicCalls")
	}

	# see if its an system command file
	line="";
	if (excmd !~ /^[[:space:]]*"?[$]/) {
		cmd="which "excmd; cmd | getline line; close(cmd);
		if (line) {
			return createNode(line, "externalCmd", "file", "fileGroup:files")
		}
	}

	# see if its a bash built command file
	line="";
	cmd="bash -c \"type -t "excmd"\""; cmd | getline line; close(cmd);
	if (line) {
		return createNode(line, "externalCmd", "builtin", "fileGroup:builtins")
	}


	# see if its an system command file
	line="";
	if (excmd !~ /^[[:space:]]*"?[$]/) {
		cmd="which "excmd; cmd | getline line; close(cmd);
		if (line) {
			return createNode(line, "externalCmd", "file", "fileGroup:files")
		}
	}

	if (!("externalCmd:"excmd in nodes))
		bgtraceVars2("-1","UNCLASSIFIED EXCMD cmd",excmd   ,"                      context",context)
	return createNode(excmd, "externalCmd", "unclassified", "fileGroup:unclassified")
}


#	{ data: {id: 'externalCmd:$_this.$name="${value//\\n/'\n'}"', label: ''\n'}"'                      , nodeType: 'externalCmd'   , parent: 'project:foriegn'                            }, classes: ''},
function sanitizeEXCMD(excmd) {
	excmd=gensub(/\//,"%2F","g",excmd)
	excmd=gensub(/"/,"%22","g",excmd)
	excmd=gensub(/'/,"%27","g",excmd)
	excmd=gensub(/\\/,"%5C","g",excmd)
	# excmd=gensub(//,"","g",excmd)
	return excmd
}

# ###: Function Definition
# LNE: 105
# FNC: oob_helpMode
# EXCMD: bgCmdlineParse
# EXCMD: basename
# EXCMD: man
# ...
# Codes:
#    FNC:   the name of the function
#    LNE:   the line number of hte function declaration
#    EXCMD: function invoked an external cmd (all comands are external)
#    EXSET: function assign a variable that is global to it
#    EXVAR: function referenced a variable that is global to it
#    SCP:   if the function is defined inside another function, this is the name of that function
#    CTX:   if the function is not defined at global scope, this is the symbol stack that descibes where it is
# If SCP: or CTX: are set, then its not a typical dependency. We should ignore them for now but eventually figure out how to
# handle a case like bg_coreDebug.sh defining empty stubs in case bgtrace is not active.
inputMode=="parserOutput" && $1=="###:" && $2=="Function" { processFuncDeps(); }
function processFuncDeps(        done,key,lineno, funcName, EXCMD,EXVAR, containingFunc,containingContext,tmp,target,subType) {
	arrayCreate(EXCMD);
	arrayCreate(EXSET);
	arrayCreate(EXVAR);
	while (!done && (getline) >0) {
		switch ($1) {
			case "FNC:":
				funcName=$2;
				if (nodes["file:"file_ID]["subType"] ~ /^cmd/)
					funcName=registerCmdFunc(nodes["file:"file_ID]["basename"], funcName)
				break;
			case "LNE:": lineno=$2; break;
			case "EXCMD:": EXCMD[gensub(/^[[:space:]]*EXCMD:[[:space:]]*/,"","g",$0)]=""; break;
			case "EXSET:": EXSET[$2]=""; break;
			case "EXVAR:": EXVAR[$2]=""; break;
			case "SCP:": containingFunc=gensub(/[(][)]$/,"","g",$2); break;
			case "CTX:": containingContext=$2; break;

			# blank line ends the section
			case "":     done="1"; break;
			case "###:": assert("there was no space between parser output sections at raw data line "NR); break;
		}
	}
	if (!funcName) assert("a parsed function block must contain the FNC: line")

	if (("import" in EXCMD) && (funcName in EXCMD)) {
bgtraceVars2("fnC: "funcName" in file="file_ID" detected as a ondemandStub","")
		subType="ondemandStub"
	}

	# functions contained in other functions or in conditional statements are special and pretty rare so ignore them for now
	if (!containingFunc && !containingContext) {
		key="func:"funcName;

		# since the file's source code was parse just before its bashParse output we are in now, the function's node  should have
		# already been created. If we detected that this is a stub, however, we can call createNode in any case b/c it has the code
		# to resolve the conflict as long as one of the conflicting functions is an ondemandStub
		if (subType=="ondemandStub") {
			key=createNode(funcName, "func", subType, "file:"file_ID);
		}

		# if key does not exist in nodes its probalby a logic error in this file.
		if (!(key in nodes)) {
			bgtraceVars2("-1","funcName",funcName   ,"file_ID",file_ID  ,"  this func was not added in the content pass","")
			createNode(funcName, "func", subType, "file:"file_ID);
		}

		nodes[key]["lineno"]=lineno;
		for (target in EXCMD)
			nodes[key]["EXCMD"][target]=""
		for (target in EXSET)
			nodes[key]["EXSET"][target]=""
		for (target in EXVAR)
			nodes[key]["EXVAR"][target]=""
	}
}


##################################################################################################################################
# start of a Post Processing section.

# make fileGroups for files with a common prefix > 6 characters
function createFileGroupsForSimilarNamedFiles(                        fileGroups,fileGroup,filename,id,lastFilename,lastNode,saveSorted_in,i,prefix,key,type,parent,parts) {
	saveSorted_in=PROCINFO["sorted_in"]
	PROCINFO["sorted_in"] = "@ind_str_asc";

	# fileGroups[<prefix>]=" <file1> ...<fileN> "
	arrayCreate(fileGroups);
	for (id in nodes) {
		# Note: maybe this algorithm would be clearer if we did files and funcs separately instead of in one pass like this
		switch (nodes[id]["type"]) {
			case "file": filename=nodes[id]["basename"]       ; break;
			# it kind of works for functions but there are issues. uncomment this line to try it
			#case "func": filename=gensub(/^[^:]*:/,"","g",id) ; break;
			default: filename=""; contunue;
		}
		if (!filename || filename~/bg_core/) {lastFilename=""; continue};
		if (lastFilename && (lastNode["type"] == nodes[id]["type"]) && (lastNode["parent"] == nodes[id]["parent"])) {
			for (i=1; i<=length(lastFilename) && i<=length(filename) && (substr(lastFilename, i, 1) == substr(filename, i, 1)) && (substr(lastFilename, i, 1) ~ /[-_a-z0-9]/ ); i++);
			# to be a prefix it must be a minimum length and also be at a camelCase boundry (the next letters are both caps)
			if (i >6 && ( substr(lastFilename, i, 1)substr(filename, i, 1) ~ /^.$|[A-Z.][A-Z.]/)) {
				prefix=gensub(/^[^:]:/,"","g",nodes[id]["parent"])"/"substr(filename, 1, i-1)
				key=prefix" "nodes[id]["type"]" "nodes[id]["parent"];
				if (!(key in fileGroups))
					arrayCreate2(fileGroups, key)
				fileGroups[key][lastNode["key"]]
				fileGroups[key][id]
			}
		}
		lastFilename = filename;
		arrayCopy(nodes[id], lastNode)
	}

	# now for each prefix, reparent the nodes that match the prefix
	for (fileGroup in fileGroups) {
		split(fileGroup, parts, " ")
		prefix=gensub(/^[^\/]*\//,"","g",parts[1]);
		type=parts[2];
		parent=parts[3];

		createNode(prefix, "fileGroup", "prefix", parent)
		for (id in fileGroups[fileGroup]) {
			if (id~/^[[:space:]]*$/) continue;
			if (nodes[id]["parent"] != parent)
				assert("logic error: all the ids for a prefix should have the same parent prefix="prefix" p1="nodes[id]["parent"]"  p2="parent)
			nodes[id]["parent"]="fileGroup:"prefix
		}
	}
	PROCINFO["sorted_in"] = saveSorted_in;
}

# {	data: {
# 	id: 'osHardening.standardat-lsisassanCommands',
# 	source: 'osHardening.standard',
# 	target: 'at-lsisassanCommands',
# 	edgeType: 'CompositeFileToFile',
# 	edgeWeight: '1'
# } },
function createFileToFileEdges(                  sourceKey, targetKey,id) {
	for (sourceKey in nodes)
		if (("imports" in nodes[sourceKey])) {
			if (!isarray(nodes[sourceKey]["imports"])) assert("node['imports'] must be an array")
			for (targetKey in nodes[sourceKey]["imports"]) {
				id="import:"sourceKey"_to_"targetKey
				edges[id]["id"]=sourceKey"_to_"targetKey
				edges[id]["key"]=id
				edges[id]["type"]="import"
				edges[id]["edgeType"]="import"
				edges[id]["source"]=sourceKey
				edges[id]["target"]=targetKey
				edges[id]["edgeWeight"]="100"
				arrayCreate2(edges[id],"classes")
			}
		}
}

function createEXCMDEdges(                  sourceKey, targetKey,id,key,cmd,line) {
	for (sourceKey in nodes)
		if (("EXCMD" in nodes[sourceKey])) {
			if (!isarray(nodes[sourceKey]["EXCMD"])) assert("node['EXCMD'] must be an array")
#if (sourceKey=="func:import") bgtraceVars2("nodes["sourceKey"]",nodes[sourceKey])
			for (targetKey in nodes[sourceKey]["EXCMD"]) {
				if (targetKey in nodes) {
					key="excmd:"sourceKey"_to_"targetKey
#if (targetKey~/gawk/) bgtraceVars2("key",key)
					if (key in edges) assert("overwiriting an EXCMD edge key="key)
					edges[key]["id"]=sourceKey"_to_"targetKey
					edges[key]["key"]=key
					edges[key]["type"]="EXCMD"
					edges[key]["edgeType"]="EXCMD"
					edges[key]["source"]=sourceKey
					edges[key]["target"]=targetKey
					edges[key]["edgeWeight"]="50"
					arrayCreate2(edges[key],"classes")
				} else {
					assert("targetKey not found in nodes key=",targetKey)
				}
			}
		}
}

# when we read the EXCMD: lines, not all the target nodes had been created so we could not call the registerEXCMDnode() function
# now we have all the functions in the projects entered into nodes[] so we can use registerEXCMDnode() to match them up
function fixupEXCMD(                    callerKey,target,newEXCMD) {
	for (callerKey in nodes) {
		if ("EXCMD" in nodes[callerKey]) {
			arrayCreate(newEXCMD)
			for (target in nodes[callerKey]["EXCMD"]) {
				target=registerEXCMDnode(target,  gensub(/^[^:]*:/,"","g",callerKey))
				if (target)
					newEXCMD[target]=""
			}
			arrayCreate(nodes[callerKey]["EXCMD"])
			arrayCopy(newEXCMD, nodes[callerKey]["EXCMD"])
		}
	}
}

END {

	# {
	# elements: [
	# // nodes
	#     { data: {id: n1,}},
	#     { data: {id: n2,}},
	#
	# // edges
	#     { data: {id: e1,
	#         source: n1,
	#         target: n2
	#     }}
	#     { data: {id: e1, source: n1, target: n2}}
	#   ]
	# }
	#     { data: {id: 'sandbox_commitGUI', nodeType: 'func', parent: 'bg_spSandbox.sh'}, classes: ''},

	fixupEXCMD()

	createFileGroupsForSimilarNamedFiles();

	createFileToFileEdges()

	createEXCMDEdges()

printf("") >"nodes.txt"; printfVars("-onodes.txt", "nodes")
printf("") >"edges.txt"; printfVars("-oedges.txt", "edges")

	printf("{\n");
	printf("  elements: [\n");

	printf("\n//	nodes\n\n");

	for (node in nodes) {
		parentClause=(nodes[node]["parent"]) ? (", parent: '"nodes[node]["parent"]"'")   :("")
		printf("	{ data: {id: %-40s, label: %-30s, nodeType: %-15s %-55s}, classes: '%s'},\n",
			"'"node"'",
			"'"nodes[node]["label"]"'",
			"'"nodes[node]["type"]"'",
			parentClause,
			arrayJoini(nodes[node]["classes"]," "));
	}

	printf("\n//	edges\n\n");

	# {	data: {
	# 	id: 'osHardening.standardat-lsisassanCommands',
	# 	source: 'osHardening.standard',
	# 	target: 'at-lsisassanCommands',
	# 	edgeType: 'CompositeFileToFile',
	# 	edgeWeight: '1'
	# } },
	for (id in edges) {
		if ((edges[id]["source"] in nodes) && (edges[id]["target"] in nodes) )
			printf("	{ data: {id: %-90s, source: %-40s, target: %-40s, edgeType: %-15s, edgeWeight: %-10s}, classes: '%s'},\n",
				"'"edges[id]["key"]"'",
				"'"edges[id]["source"]"'",
				"'"edges[id]["target"]"'",
				"'"edges[id]["edgeType"]"'",
				"'"edges[id]["edgeWeight"]"'",
				arrayJoini(edges[id]["classes"], " "));
		# else
		# 	bgtraceVars("id")
	}

	printf("  ]\n");
	printf("}\n");


# 	# normalize the counts to a weight between 1 and 100
# 	for (i in data_edgesCount) {
# 		data_edgesWeight[i]= (data_edgesCount[i] * 100) / maxCount;
# 		data_edgesWeight[i]= (data_edgesWeight[i]<1) ? 1 : data_edgesWeight[i];
# 	}
#
# 	for (i in data_edgesLeft) {
# 		if ((data_edgesRight[i] in data_nodeType) && (data_edgesLeft[i] in data_nodeType))
# #					if (data_edgesType[i] == "CompositeFileToFile")
# 				printf("    { data: {id: %s, source: %s, target: %s, edgeType: %s, edgeWeight: %s}},\n",
# 					'""i""', '""data_edgesLeft[i]""',
# 					'""data_edgesRight[i]""',
# 					'""data_edgesType[i]""',
# 					'""data_edgesWeight[i]""');
# 	}
#
# 	printf("  ]\n");
# 	printf("}\n");

}
