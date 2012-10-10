


function NGS (id) {
	this.pid = id;
	this.windows = [];
}

NGS.prototype.launch = function(what, where, title) {  
	var urls = {
			viewer: ['/project/phylogenetics/tools/view_sequences.html?pid=', 'Sequence Viewer'],
			phy_trim: ['/project/phylogenetics/tools/view_sequences.html?show_trimmed=1;pid=', 'Trimmed Sequence Viewer'],
			pair: ['/project/phylogenetics/tools/pair?pid=', 'Pair Builder'],
			blast: ['/project/phylogenetics/tools/blast.html?pid=', 'BLASTN'],
			data: ['/project/ngs/tools/manage_data?pid=', 'Manage data'],
			cufflinks: ['/project/ngs/tools/cufflinks_list?pid=', 'Cufflinks'],
			cuffdiff: ['/project/ngs/tools/cuffdiff_list?pid=', 'Cuffdiff'],
			tophat: ['/project/ngs/tools/tophat_list?pid=', 'TopHat'],
			//manage_sequences: ['/project/phylogenetics/tools/manage_sequences?pid=', 'Select Data']
		};

	try {
		//$('add_evidence').hide();
		//$('add_evidence_link').show();
	}
	catch (e) {}

	var host = window.location.host;
	var uri = what && urls[what]
					? 'http://' + host + urls[what][0] + $('pid').value
					: where;
	var window_title = title ? title : urls[what] ? urls[what][1] : null;
	
	
	var options = null;
	if (what == 'manage_sequences') {
		options = {
			width: 900, 
			height: 496,
			shadow: false,
			draggable: true,
			resizable: true,
			url: uri, 
			close : function() {
				if (what && this.windows[what]) {
					this.windows[what].destroy(); 
					return true;  
				}
			}
		};
	}
	
	this.windows[what] = openWindow( uri, window_title, options);
};

NGS.prototype.close_window = function(id) {
	this.windows[id] && this.windows[id].destroy();
};


NGS.prototype.add_data = function() {
	var data = [];
	$$('input[type=checkbox]').each(function(el) {
		if (el.checked) {
			$('form_add_data').submit();
		}
	});
	//console.debug(data);
};


NGS.prototype.do_trim = function(id) {
	document.location.replace('/project/ngs/tools/app_fastxtr?pid=' + this.pid + ';f=' + id);
};

NGS.prototype.do_qc_old = function(id) {
	document.location.replace('/project/ngs/tools/app_fastqc?pid=' + this.pid + ';f=' + id);
};

NGS.prototype.do_qc = function() {
	new Ajax.Request('/project/ngs/tools/do_qc', {
		method:'get',	
		parameters: {'pid': this.pid},
		onSuccess: function(transport){
				alert(transport.responseText);
			},
		onFailure: function(){
				alert('Something went wrong!\nAborting...');
			}
	});
};

var ngs, window;

//Event.observe(top, Prototype.Browser.IE ? 'load' : 'dom:loaded', function() {
Event.observe(window, 'load', function() {
	var step = document.getElementById('step') != null ? parseInt(document.getElementById('step').value, 10) : 0;
	if (console)
		console.info("step = " + step);
	if ($('pid')) {
		ngs = new NGS($('pid').value);
	}
	else {
		ngs = new NGS();
	}
	//alert("step = " + step);
	
	if (step == 1) {
	
	}
	else if (step == 2) {
		$('add').observe('click', function() {
			ngs.add_data();
		});
	}
	else if (step == 3) {
		$('app_parameters').toggle();
	}
});

//alert("step = " + Prototype.Browser.IE);