import { BGAtomPlugin, dedent }         from 'bg-atom-utils';
import { %PluginClassname% }            from './%PluginClassname%';

// Main Class for this Atom package
// %PluginClassname% provides control over the font size and lineHeight in the tree-view and in the tab bars of the 4 pane containers
// (WorkspaceCenter, and Left,Right, and Bottom Docks). Changing the font size of UI controls has the effect of zooming and its
// useful on high resolution monitors to be able to decide how big each of these UI elements should be.
class %+PluginClassname% extends BGAtomPlugin {
	constructor(state) {
		super('%packageName%', state, __filename);

		this.addCommand("%packageName%:run-tutorial",   ()=>atom.config.set('%packageName%.showWelcomeOnActivation', true));



		%PluginClassname%Tutorial.configure('%packageName%.showWelcomeOnActivation');
	}

	destroy() {
		super.destroy()
	}


	// save our state so so that it persists accross Atom starts
	serialize() {
	}

};

//"configSchema":
// %PluginClassname%.config =  {
// 	"showWelcomeOnActivation": {
// 		"type": "boolean",
// 		"default": true,
// 		"title": "Show Welcome Tutorial",
// 		"description": "Checking this will activate the welcome dialog one more time"
// 	},
// 	"enable-global-keymaps": {
// 		"type": "boolean",
// 		"default": true,
// 		"title": "Enable Global Keymaps",
// 		"description": "Deselecting this will disable only some of the the keymaps provided by this package.  Only the ones associated with this package's modal dialog will remain."
// 	}
// }

export default BGAtomPlugin.Export(%PluginClassname%);
