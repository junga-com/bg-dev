@include "bg_core.awk"

# Params:
# Use -v <varname>="" on the awk command line
#    <utFilePath>: filepath to the testcase script being operated on

BEGIN {
	if (ENVIRON["UT_DEBUG"]) bgtrace("runner.awk starts BEGIN")
	utFile=gensub(/(^.*\/)|(\.ut$)/,"","g",utFilePath)

	utFileHiddenBase=gensub(/\/[^\/]*$/,"","g",utFilePath)"/."gensub(/(^.*\/)|\.[^\.]*$/,"","g",utFilePath)""

	runFile   = utFileHiddenBase".run"    # filepath to merge input into
	platoFile = utFileHiddenBase".plato"  # filepath to the saved/expected testcase results
	orderFile = utFileHiddenBase".ids"    # the canonical ordered list of utIDs that are currenlty contained in the .ut (output of "./<name>.ut list")
	tmpOut    = utFileHiddenBase".tmp"    # a tmp file to collect the new output. it is removed at the end of the run

	#printfVars("utFile utFileHiddenBase runFile platoFile orderFile")

	# these are aliases for the three different file sources where we get the three versions of the testcase output from.
	# during the file scans, the 'fType' variable is set to one of these. In the END block, use new, run, or plato
	new="-"
	run=runFile
	plato=platoFile

	# data[new|run|plato][utID]["output"][0..N]=<output lines>
	# data[new|run|plato][utID]["result"]=finish|ERROR:
	# data[new|run|plato][utID]["errMsg"]=<text>
	arrayCreate(data)
	arrayCreate2(data, new)
	arrayCreate2(data, run)
	arrayCreate2(data, plato)


	queueFileToScan("-") # once we queue a input file, it wont automatically read stdin so we have to manually tell it to with "-"
	if (fsExists(runFile))   queueFileToScan(runFile)
	if (fsExists(platoFile)) queueFileToScan(platoFile)

	# read the ids list normalizing the ids to have exactly 2 colons (3 parts utFile:utFunc:utParams)
	arrayCreate(exitingUTIDs)
	arrayCreate(order)
	if (orderFile) {
		while ((getline line < orderFile) >0) {
			gsub(/(^[[:space:]]*)|([[:space:]]*$)/,"",line)
			switch (length(gensub(/[^:]/,"","g", line))) {
				case 1: line=utFile":"line; break
				case 2: break
				case 3: line=gensub(/^[^:]*:/,"","g",line); break
				default: assert("logic error. found illformed utID("line") in file=("orderFile")")
			}
			arrayPush(order, line)
			exitingUTIDs[line]=(length(order))
		}
		close(orderFile)
	}
	if (ENVIRON["UT_DEBUG"]) bgtrace("runner.awk finishes BEGIN")
}

BEGINFILE {
	fType=FILENAME
	utID=""
}

# utfReport sends alternate stdin pipe contents. Each line is just the utID that we should report on
fType==new && $1=="REPORT-ONLY" {reportOnlyMode="1"; next}
fType==new && reportOnlyMode {
	utID=$1
	arrayCreate2(data[fType], utID)
	arrayCreate2(data[fType][utID], "output")
	arrayCreate2(data[fType][utID], "filters")
	data[fType][utID]["utID"]=utID
	utID=""
	next
}



# start of new testcase section
!utID && $1=="##" && $3=="start" {
	utID=$2
	arrayCreate2(data[fType], utID)
	arrayCreate2(data[fType][utID], "output")
	arrayCreate2(data[fType][utID], "filters")
	data[fType][utID]["utID"]=utID

	# add global filters
	if (fType==new) {
		nextFilterInd=length(data[fType][utID]["filters"]) + 1
		arrayCreate2(data[fType][utID]["filters"], nextFilterInd)
		data[fType][utID]["filters"][nextFilterInd]["match"]="/tmp/tmp[.].*\\>"
		data[fType][utID]["filters"][nextFilterInd]["replace"]="/tmp/tmp.<redacted>"

		nextFilterInd=length(data[fType][utID]["filters"]) + 1
		arrayCreate2(data[fType][utID]["filters"], nextFilterInd)
		data[fType][utID]["filters"][nextFilterInd]["match"]="/tmp/bgmktemp[.].*\\>"
		data[fType][utID]["filters"][nextFilterInd]["replace"]="/tmp/bgmktemp.<redacted>"

		nextFilterInd=length(data[fType][utID]["filters"]) + 1
		arrayCreate2(data[fType][utID]["filters"], nextFilterInd)
		data[fType][utID]["filters"][nextFilterInd]["match"]="heap_([^_]*)_([[:alnum:]]*)"
		data[fType][utID]["filters"][nextFilterInd]["replace"]="heap_\\1_<redacted>"

		nextFilterInd=length(data[fType][utID]["filters"]) + 1
		arrayCreate2(data[fType][utID]["filters"], nextFilterInd)
		data[fType][utID]["filters"][nextFilterInd]["match"]="(vmtCacheNum[[:space:]]*=).[0-9]*"
		data[fType][utID]["filters"][nextFilterInd]["replace"]="\\1<redacted>"
	}
	next
}

# testcase section ends successfully
$1=="##" && $3=="finished" {
	data[fType][utID]["result"]=$3
	utID=""
}

# testcase section ends in ERROR
$1=="##" && $3=="ERROR:" {
	data[fType][utID]["result"]="ERROR:"
	data[fType][utID]["errMsg"]=gensub(/^.*ERROR:/,"","g", $0)
	utID=""
}

# ut filter 's/heap_\([^_]*\)_\([^_ ]*\)/heap_\1_<redacted>/g'
fType==new && utID && $1=="##" && $2=="|" && $3=="ut" && $4=="filter" {
	filter=gensub(/(^[^']*')|('[^']*$)/,"", "g", $0)
	split(filter, filterParts, "###")
	nextFilterInd=length(data[fType][utID]["filters"]) + 1
	arrayCreate2(data[fType][utID]["filters"], nextFilterInd)
	data[fType][utID]["filters"][nextFilterInd]["match"]=filterParts[1]
	data[fType][utID]["filters"][nextFilterInd]["replace"]=filterParts[2]
}

# collect the testcase output
utID {
	arrayPush(data[fType][utID]["output"], $0)
}

END {
	if (ENVIRON["UT_DEBUG"]) bgtrace("runner.awk starts END")
	arrayCreate(resultLists)
	arrayCreate2(resultLists, "uninit")
	arrayCreate2(resultLists, "pass")
	arrayCreate2(resultLists, "fail")
	arrayCreate2(resultLists, "error")

	arrayCreate(modLists)
	arrayCreate2(modLists, "new")
	arrayCreate2(modLists, "updated")
	arrayCreate2(modLists, "unchanged")
	arrayCreate2(modLists, "removed")

	printf("") > tmpOut

	#bgtraceVars("data")

	for (i=1; i<=length(order); i++) {
		utID = order[i]

		# if (0) printf("%s %s %s : %s\n",
		# 	(utID in data[new]) ? "X" : "-",
		# 	(utID in data[run]) ? "X" : "-",
		# 	(utID in data[plato]) ? "X" : "-",
		# 	utID)

		# modState
		#      new      : adding new TC to run file
		#      updated  : replacing TC in run file
		#      unchanged: no difference in new and run
		modState=""

		# resultsState
		#      ""       not in this run (missing from new)
		#      uninit   plato does not exist
		#      pass     new and plato outputs are the same
		#      fail     new and plato outputs are NOT the same
		#      error    !pass and "ERROR:" in end block
		resultsState=""
		if (utID in data[new]) {
			# apply output filters to the new content. These filters redact parts of the output that change each run like random names
			for (indx in data[new][utID]["filters"]) {
				fmatch=data[new][utID]["filters"][indx]["match"]
				freplace=data[new][utID]["filters"][indx]["replace"]
				for (line in data[new][utID]["output"]) {
					data[new][utID]["output"][line]=gensub(fmatch, freplace, "g", data[new][utID]["output"][line])
				}
			}


			# compare the new with run and then copy new into run
			if (!reportOnlyMode) {
				if (utID in data[run]) {
					modState = utOutputCmpInclComments(data[new][utID]["output"],  data[run][utID]["output"])
				} else {
					arrayCreate2(data[run], utID)
					modState="new"
				}
				arrayCopy(data[new][utID],  data[run][utID])
				arrayPush(modLists[modState], utID)
			} else
				modState="unchanged"

			# determine the pass/fail/error/uninit state by comparing run and plato. Note that if run and plato output are a match,
			# we consider it passed even if the output indicates a setup ERROR:  This allows bg_unitTest.sh.ut to include testcases
			# that test when setup errors are recorded.
			if (utID in data[plato]) {
				resultsState = utOutputCmp(data[run][utID]["output"],  data[plato][utID]["output"])
			} else
				resultsState="uninit"
			if (resultsState!="pass" && data[run][utID]["result"]~/ERROR/)
				resultsState="error"
			arrayPush(resultLists[resultsState], utID)

			# print the one line summary record for this utID to stdout
			printf("%-10s %-10s %s\n", norm(resultsState), norm(modState), utID)
		}

		if (!reportOnlyMode && (utID in data[run])) {
			outputTestCase(data[run][utID])
		}
	}

	if (!reportOnlyMode ) for (utID in data[run]) if ( ! (utID in exitingUTIDs)) {
			arrayPush(modLists["removed"], utID)
			printf("%-10s %-10s %s\n", norm(""), "removed", utID)
	}

	# save the new output back into run if it changed
	if (!reportOnlyMode)
		updateIfDifferent(tmpOut, runFile)
	if (fsExists(tmpOut))
		fsRemove(tmpOut)

	if (ENVIRON["UT_DEBUG"]) bgtrace("runner.awk finishes END")
}

function outputTestCase(ut                               ,i) {
	#printfVars2(0, "ut", ut)
	printf("\n") >> tmpOut
	printf("###############################################################################################################################\n") >> tmpOut
	printf("## %s start\n", ut["utID"]) >> tmpOut
	for (i=1; i <= length(ut["output"]); i++)
		printf("%s\n", ut["output"][i]) >> tmpOut
	printf("## %s %s%s\n", ut["utID"], ut["result"], ut["errMsg"]) >> tmpOut
	printf("###############################################################################################################################\n") >> tmpOut
	printf("\n") >> tmpOut
}

function utOutputCmp(a1, a2                                     ,i1,i2) {
	i1=i2=1
	while (i1<=length(a1) || i2<=length(a2) ) {
		# advance both sides over comment lines to the end or the next non-comment line
		while (i1<=length(a1) && a1[i1]~/^[[:space:]]*#/) i1++
		while (i2<=length(a2) && a2[i2]~/^[[:space:]]*#/) i2++

		# advance both sides for as long as they are equal
		while (i1<=length(a1) && i2<=length(a2) && a1[i1] == a2[i2]) {i1++;i2++}

		if ( (i1<=length(a1) && a1[i1]!~/^[[:space:]]*#/)  ||  (i2<=length(a2) && a2[i2]!~/^[[:space:]]*#/) ) {
			return "fail"
		}
	}
	return "pass"
}

function utOutputCmpInclComments(a1, a2                                     ,i1,i2) {
	i1=i2=1
	while (i1<=length(a1) && i2<=length(a2) ) {
		# advance both sides for as long as they are equal
		while (i1<=length(a1) && i2<=length(a2) && a1[i1] == a2[i2]) {i1++;i2++}

		if ( (i1<=length(a1)) ||  (i2<=length(a2)) )
			return "updated"
	}
	return "unchanged"
}
