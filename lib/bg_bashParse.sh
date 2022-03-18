#!/bin/bash

# if your library depends on other libraries, import them here
#import <libName> ;$L1;$L2

# usage: bparse_build [<project>]
# parse the scripts for vinstalled projects to build a cyjs data file for visualizing the graph of project, file and function
# dependencies
# Params:
#    <project> : the project whose scripts will be included in the graph data. default is "all" which includes all vinstalled projects
function bparse_build()
{
	local project="$1"; shift
	awk '
		$1=="###:" {
			if ($3=="File") {
				# this filename parsing algorithm assumes that ...
				#    1) all the script files are underneith a sandbox folder
				#    2) the sandbox folder is the first folder that matches the /??- naming convention
				#    3) the project folder is the first folder under the sandbox folder

				# basename   : script name with no path (includes extension if there is one)
				# filename   : relative path of script from the sandbox (project is the first folder)
				# project    : the first folder name after the sandbox folder
				# fileType   : command|library   based on whether or not is has an extension

				filename=$4;
				while (filename~"/" && filename!~"^/?..-")
					sub("^[^/]*/","",filename)
			 	sub("^[^/]*/","",filename); # remove the sandbox folder

				project=filename; sub("/.*$","",project)
				basename=filename; sub("^.*/","",basename)

				fileType=(basename ~ /[.]/) ? "library" : "command"

				data_nodeType[project]="project"

				if (basename in data_nodeType && data_nodeType[basename] != "project") {
					data_nodeType[filename]="file"
					data_nodeParent[filename]=project
					data_dupeFiles[basename]=basename"," ((data_dupeFiles[basename]) ? data_dupeFiles[basename] : data_nodeParent[basename])
				}
				data_nodeType[basename]="file"

				# classify the type of code file. We typically want to focus on libraries so put Commands and UnitTests into fileGroups
				# to isolate them
				if (basename ~ /[.]ut$/) {
					if (!(project"UnitTests" in data_nodeType)) {
						data_nodeType[project"UnitTests"]="fileGroup"
						data_nodeParent[project"UnitTests"]=project
						data_nodeClasses[project"UnitTests"]="unitTest "
					}
					data_nodeParent[basename]=project"UnitTests"
					data_nodeClasses[basename]="unitTest "

				} else if (basename !~ /[.]/) {
					if (!(project"Commands" in data_nodeType)) {
						data_nodeType[project"Commands"]="fileGroup"
						data_nodeParent[project"Commands"]=project
						data_nodeClasses[project"Commands"]="command "
					}
					data_nodeParent[basename]=project"Commands"
					data_nodeClasses[basename]="command "

				} else {
					data_nodeParent[basename]=project
					data_nodeClasses[basename]="library "
				}

			} else if ($2 == "Function") {
				inSectType="Function";
			} else if ($2 == "Global") {
				inSectType="Global";
			} else {
				inSectType="";
				fnc="";
				lne="";
				scp="";
				ctx="";
			}
		}

		$1=="EXCMD:" && inSectType=="Function" {
			eggeCount++;
			data_edgesLeft["e"eggeCount]=fnc
			data_edgesType["e"eggeCount]="FncCallsFnc"
			data_edgesRight["e"eggeCount]=$2
			data_edgesCount["e"eggeCount]++;
		}

		$1=="EXCMD:" && inSectType=="Global" {
			eggeCount++;
			data_edgesLeft["e"eggeCount]=basename
			data_edgesType["e"eggeCount]="GlbCallsFnc"
			data_edgesRight["e"eggeCount]=$2
			data_edgesCount["e"eggeCount]++;
		}

		$1=="EXVAR:" && inSectType=="Function" {
			eggeCount++;
			data_edgesLeft["e"eggeCount]=fnc
			data_edgesType["e"eggeCount]="FncUsesVar"
			data_edgesRight["e"eggeCount]=$2
			data_edgesCount["e"eggeCount]++;
		}

		$1=="EXVAR:" && inSectType=="Global" {
			eggeCount++;
			data_edgesLeft["e"eggeCount]=basename
			data_edgesType["e"eggeCount]="FileUsesVar"
			data_edgesRight["e"eggeCount]=$2
			data_edgesCount["e"eggeCount]++;
		}

		$1=="FNC:" {
			fnc=$2;
			if (fnc in data_nodeType && data_nodeParent[fnc]!=basename) {
				data_nodeType[basename":"fnc]="func"
				data_nodeParent[basename":"fnc]=basename
				data_dupeFuncs[fnc]=basename"," ((data_dupeFuncs[fnc]) ? data_dupeFuncs[fnc] : data_nodeParent[fnc])
			}
			if (fileType == "command") {
				data_nodeType[basename":"fnc]="func"
				data_nodeParent[basename":"fnc]=basename;
			} else {
				data_nodeType[fnc]="func"
				data_nodeParent[fnc]=basename;
			}
		}
		$1=="LNE:" {lne=$2;}
		$1=="SCP:" {scp=$2;}
		$1=="CTX:" {ctx=$2;}

		END {
			SQ="'\''"
			#printf("node count = %s\n", length(data_nodeType));
			#printf("edge count = %s\n", length(data_edgesLeft));

			for (fnc in data_dupeFuncs) {
				printf("\nwarning: function "SQ"%s"SQ" appears in multiple files \n", fnc) >> "/dev/stderr"
				printf("           "SQ"%s"SQ"\n", gensub(",",SQ"\n           "SQ,"g", data_dupeFuncs[fnc])) >> "/dev/stderr"
			}

			for (file in data_dupeFiles) {
				printf("\nwarning: file "SQ"%s"SQ" appears in multiple projects \n", file) >> "/dev/stderr"
				printf("           "SQ"%s"SQ"\n", gensub(",",SQ"\n           "SQ,"g", data_dupeFiles[file])) >> "/dev/stderr"
			}

			PROCINFO["sorted_in"] = "@ind_str_asc";
			split("",fileGroups);
			for (node in data_nodeType) {
				if (data_nodeType[node] != "file" || node ~ /[.]ut$/ || data_nodeClasses[node] !~ /library/) continue;
				if (lastNode) {
					for (i=1; i<=length(lastNode) && i<=length(node) && (substr(lastNode, i, 1) == substr(node, i, 1)) && (substr(lastNode, i, 1) ~ /[-_a-z0-9]/ ); i++);
					if (i >6 && ( substr(lastNode, i, 1)substr(node, i, 1) ~ /^.$|[A-Z.][A-Z.]/))
						fileGroups[substr(node, 1, i-1)]=(fileGroups[substr(node, 1, i-1)]) ? fileGroups[substr(node, 1, i-1)]","node : lastNode "," node;
				}
				lastNode = node;
			}
			for (fileGroup in fileGroups) {
				#printf("grp: %-12s : %s\n", i, fileGroups[i]) >> "/dev/stderr";
				data_nodeType[fileGroup]="fileGroup"
				for (node in data_nodeType) {
					if (data_nodeType[node] != "file" || node ~ /[.]ut$/ || data_nodeClasses[node] !~ /library/) continue;
					if (node ~ "^"fileGroup) {
						data_nodeParent[fileGroup]=data_nodeParent[node];
						data_nodeParent[node]=fileGroup;
					}
				}
			}
			PROCINFO["sorted_in"] = "";

			# {
			# elements: [
			#     { data: {id: n1,}},
			#     { data: {id: n2,}},
			#
			#     { data: {id: e1,
			#         source: n1,
			#         target: n2
			#     }}
			#     { data: {id: e1, source: n1, target: n2}}
			#   ]
			# }

			printf("{\n");
			printf("  elements: [\n");

			for (node in data_nodeType) {
				parentClause=(node in data_nodeParent) ? ", parent: "SQ""data_nodeParent[node]""SQ : ""
				switch (data_nodeType[node]) {
					case "project":
						printf("    { data: {id: %s, nodeType: "SQ"project"SQ"}, classes: "SQ"%s"SQ"},\n", SQ""node""SQ, data_nodeClasses[node]);
						break;
					case "fileGroup":
						printf("    { data: {id: %s, nodeType: "SQ"fileGroup"SQ"%s}, classes: "SQ"%s"SQ"},\n", SQ""node""SQ, parentClause, data_nodeClasses[node]);
						break;
					case "file":
						printf("    { data: {id: %s, nodeType: "SQ"file"SQ"%s}, classes: "SQ"%s"SQ"},\n", SQ""node""SQ, parentClause, data_nodeClasses[node]);
						break;
					case "func":
						printf("    { data: {id: %s, nodeType: "SQ"func"SQ"%s}, classes: "SQ"%s"SQ"},\n", SQ""node""SQ, parentClause, data_nodeClasses[node]);
						break;
					default:
						printf("\nwarning: unknown node type "SQ"%s"SQ" for node "SQ"%s"SQ"\n", data_nodeType[node], node) >> "/dev/stderr"
						break;
				}
			}

			printf("\n    // EDGES\n\n");

			# generated weighted edges to summarize the relation between files
			for (i in data_edgesLeft) {
				if ((data_edgesRight[i] in data_nodeType) && (data_edgesLeft[i] in data_nodeType))
					switch (data_edgesType[i]) {
						case "FncCallsFnc":
						case "GlbCallsFnc":
							if (data_edgesType[i]=="GlbCallsFnc")
								fileLeft=data_edgesLeft[i];
							else
								fileLeft=data_nodeParent[data_edgesLeft[i]];
							fileRight=data_nodeParent[data_edgesRight[i]];
							newEdge=fileLeft""fileRight;
							data_edgesLeft[newEdge]=fileLeft;
							data_edgesRight[newEdge]=fileRight;
							data_edgesType[newEdge]="CompositeFileToFile";
							data_edgesCount[newEdge]++;
							maxCount=(data_edgesCount[newEdge] > maxCount) ? data_edgesCount[newEdge] : maxCount;
							break;
						case "FncUsesVar":
							break;
						case "FileUsesVar":
							break;
					}
			}

			# normalize the counts to a weight between 1 and 100
			for (i in data_edgesCount) {
				data_edgesWeight[i]= (data_edgesCount[i] * 100) / maxCount;
				data_edgesWeight[i]= (data_edgesWeight[i]<1) ? 1 : data_edgesWeight[i];
			}

			for (i in data_edgesLeft) {
				if ((data_edgesRight[i] in data_nodeType) && (data_edgesLeft[i] in data_nodeType))
#					if (data_edgesType[i] == "CompositeFileToFile")
						printf("    { data: {id: %s, source: %s, target: %s, edgeType: %s, edgeWeight: %s}},\n",
							SQ""i""SQ, SQ""data_edgesLeft[i]""SQ,
							SQ""data_edgesRight[i]""SQ,
							SQ""data_edgesType[i]""SQ,
							SQ""data_edgesWeight[i]""SQ);
			}

			printf("  ]\n");
			printf("}\n");

		}

	' < <(
		while IFS="" read -r codeFile; do
			bashParse --parse-tree-print "$codeFile" || assertError
		done < <(
			manifestGet -o '$4'  ${project:+--pkg=$project} ".*bash" ".*"
		)
	)
}
