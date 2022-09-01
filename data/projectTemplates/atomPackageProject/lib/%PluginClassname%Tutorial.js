import { Tutorial,dedent } from 'bg-atom-utils';
import { DispatchCommand } from 'bg-atom-utils';

export class %PluginClassname%Tutorial extends Tutorial {
	static configure(configKey) {
		%PluginClassname%Tutorial.configKey = configKey;
		atom.config.addDep(%PluginClassname%Tutorial.configKey, %PluginClassname%Tutorial)

		%PluginClassname%Tutorial.onConfigChanged({});
	}

	static onConfigChanged({key, newValue}) {
		if (!newValue) newValue=atom.config.get(%PluginClassname%Tutorial.configKey);
		if (newValue || Tutorial.resumeStateExists()) {
			if (newValue) atom.config.set(%PluginClassname%Tutorial.configKey, false);
			if (!%PluginClassname%Tutorial.instance)
				%PluginClassname%Tutorial.instance = new %PluginClassname%Tutorial();
		}
	}

	constructor() {
		super('bg-ui-font-resizer');
		if (!this.doResumeState())
			this.pageStart();
	}

	pageStart() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(1/6) Thank you for installing bg-ui-font-sizer.</h3>
			<p>You can now zoom in and zoom out the tree-view pane and also the tabs on each of the docks and workspace center.</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Next',          onDidClick: ()=>{this.page1_1()}},
				{text: 'Ok, got it',    onDidClick: ()=>{this.end()}}
			]
		})
	}

	page1_1() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(2/6) About Keymaps</h3>
			<p>Typically, the packages I write do not install any global keymaps, but this one is an exception becuase I think that some obviously fit into atom's default</p>
			<p>The settings page has an option to disable only the global keymaps in case you prefer to define your own.</p>
			<p>The settings page goes into detail about why I choose the keymaps and how to modify them</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Open settings', onDidClick: ()=>{atom.workspace.open('atom://config/packages/bg-ui-font-sizer/');}},
				{text: 'Back',          onDidClick: ()=>{this.pageStart()}},
				{text: 'Next',          onDidClick: ()=>{this.page2()}},
				{text: 'Ok, got it',    onDidClick: ()=>{this.end()}}
			]
		})
	}

	page2() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(3/6) Zooming the Tree View</h3>
			<p>You are probably used to the \`cntr plus/minus\` keys zooming in and out the editor window. Now when your focus is in the tree-view
			   those same keys will zoom in and out the tree-view. </p>
			<p>In the tree-view you can also control the line height to sqeeze or spread out the lines vertically with \`cntr-up/down\`</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Back',          onDidClick: ()=>{this.page1_1()}},
				{text: 'Next',          onDidClick: ()=>{this.page2_5()}},
				{text: 'Ok, got it',    onDidClick: ()=>{this.end()}}
			]
		})
	}

	page2_5() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(4/6) Tree View Toolbar</h3>
			<p>If you install the bg-tree-view-toolbar package, the toolbar at the top of the tree view will have a button group
			   to change the font size and line height (aka zoom in/out). Those buttons invoke the commands provided by this package</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Install Toolbar',onDidClick: ()=>{this.installToolbar()}},
				{text: 'Back',          onDidClick: ()=>{this.page2()}},
				{text: 'Next',          onDidClick: ()=>{this.page3()}},
				{text: 'Ok, got it',    onDidClick: ()=>{this.end()}}
			]
		})
	}

	page3() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(5/6) Zooming the Tabs</h3>
			<p>Each Dock and WorkspaceCenter can hold multiple items and by default uses a tab bar to navigate.</p>
			<p>By adding the shift key to the cntr plus/minus key strokes (\`cntr-shift-plus/minus\`), you can zoom in and out the tabs of the dock or workspace center that
			   currently has your focus.</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Back',          onDidClick: ()=>{this.page2_5()}},
				{text: 'Next',          onDidClick: ()=>{this.page4()}},
				{text: 'Ok, got it',    onDidClick: ()=>{this.end()}}
			]
		})
	}

	page4() {
		if (this.dialog) this.dialog.dismiss();
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>(6/6) Zooming the Tabs</h3>
			<p>There is also a modal dialog window that you can pop up to adust all the tab locations. While that dialog is open,
			   the plain \`cntr plus/minus\` keys will operate on the tab bar that is selected in the dialog.</p>
			<p>Add the alt and shift keys to the cntr plus/minus keystrokes (\`cntr-shift-alt-plus/minus\`) to open the modal dialog</p>
			`, {
			dismissable: true,
			buttons: [
				{text: 'Open Dialog',   onDidClick: ()=>{DispatchCommand('bg-tabs:toggle-size-dialog')}},
				{text: 'Back',          onDidClick: ()=>{this.page3()}},
				{text: 'Close',         onDidClick: ()=>{this.end()}}
			]
		})
	}


	end() {
		this.dialog.dismiss();
		%PluginClassname%Tutorial.instance = null;
		this.dialog = atom.notifications.addInfo(dedent`
			<h3>Press &lt;esc&gt; to get back to work..</h3>
			<p>If you have any questions or comments, please click on the \`Report Issues\` button near the top of the settings page.</p>
			<p>To run this tutorial again, enable its checkbox on the bg-tree-view-toolbar settings page or look for the tutorial command in the tool pallette.</p>
			`, {
			dismissable: true
		})
	}

	openSettings() {
		atom.workspace.open('atom://config/packages/'+this.packageName+'/');
	}

	installToolbar() {
		atom.packages.installPackage('bg-tree-view-toolbar');
	}

}
