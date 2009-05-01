function step_one() {
	if (! $('seq_src_upload').checked && !$('seq_src_sample').checked) {
		alert("Source not selected!");
		return;
	}

	var f = $('forma1');
	var has_file = $('seq_src_upload').checked && ( $('seq_file').value != '' );
	var has_sample = $('seq_src_sample').checked && $('specie').selectedIndex != -1;
	if (!has_file && !has_sample) {
		alert("You must upload file or select a sample organism!");
		return;
	}
	if (has_sample) {
		alert("Method not yet supported!");
		return;
	}
	f.submit();
}

function select_source(el) {
	if (el && el.value == 'upload') {
		$('specie').selectedIndex = -1;
		//$('organism_info').show();
	}
	else if (el && el.value == 'sample') {
		//$('organism_info').hide();
	}
}

function set_source(s) {
	var el = $('seq_src_' + s);
	if (el) {
		//el.checked = true;
		el.click();
	}
}

