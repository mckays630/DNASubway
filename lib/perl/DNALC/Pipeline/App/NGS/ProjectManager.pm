package DNALC::Pipeline::App::NGS::ProjectManager;

#use common::sense;
use strict;
use warnings;

use aliased 'DNALC::Pipeline::NGS::Job';
use aliased 'DNALC::Pipeline::NGS::JobParam';
use aliased 'DNALC::Pipeline::NGS::Project';
use aliased 'DNALC::Pipeline::NGS::DataFile';
use aliased 'DNALC::Pipeline::NGS::DataSource';
use aliased 'DNALC::Pipeline::NGS::JobTrack';

use DNALC::Pipeline::Config ();
use DNALC::Pipeline::Task ();
use DNALC::Pipeline::CacheMemcached ();

use iPlant::FoundationalAPI ();
use iPlant::FoundationalAPI::Constants ':all';

use Archive::Zip ();
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use File::Path qw/make_path/;
use File::Basename qw/basename/;
use Carp;
use JSON::XS ();
use Data::Dumper;

{
	my %status_map = (
			"not-processed" => 1,
			"done"          => 2,
			"error"         => 3,
			"processing"    => 4
		);
	my %status_id_to_name = reverse %status_map;

	sub new {
		my ($class, $params) = @_;
		my $self = bless {
			_mc => DNALC::Pipeline::CacheMemcached->new,
			api_instance => undef,
			debug => $params->{debug} || undef,
		}, __PACKAGE__;

		my $project = $params->{project};

		if ($project) {
			if (ref $project eq '' && $project =~ /^\d+$/) {
				my $proj = Project->retrieve($project);
				unless ($proj) {
					print STDERR  "Project with id=$project wasn't found!", $/;
				}
				else {
					$self->project($proj);
				}
			}
			else { # we assume it's an instance of a project
				$self->project($project);
			}
		}

		#------
		my %task_id_to_name = ();
		my %task_name_to_id = ();
		my $tasks = DNALC::Pipeline::Task->search_like(name => 'ngs_%');
		while (my $task = $tasks->next) {
			next unless $task->enabled;
			$task_id_to_name{ $task->id } = $task->name;
			$task_name_to_id{ $task->name } = $task->id;
		}
		$self->{task_id_to_name} = \%task_id_to_name;
		$self->{task_name_to_id} = \%task_name_to_id;
		#-------
		$self->{config} = DNALC::Pipeline::Config->new->cf('NGS');

		$self;
	}

	# -------------------------------------
	sub create_project {
		my ($self, $params) = @_;

		my ($status, $msg) = ('fail', '');
		my $user_id = $params->{user_id};
		my $name = $params->{name};
			
		my $proj = $self->search(user_id => $user_id, name => $name);
		if ($proj){
			return {status => 'fail', message => "There is already a project named \"$name\"."};
			print STDERR $msg, $/;
		}
			
		$proj = eval {
				Project->create({
						user_id => $user_id,
						name => $name,
						type => $params->{type} || '',
						organism => $params->{organism} || '',
						common_name => $params->{common_name} || '',
						description => $params->{description} || '',
					});
			};
		if ($@){
			$msg = "Error creating the project: $@";
			print STDERR $msg, $/;
			return {status => 'fail', message => $msg};
		}

		$self->project($proj);
		$self->create_work_dir;

		return {status => 'success', message => $msg};
	}

	#--------------------------------------
	#
	sub config {
		return shift->{config};
	}

	#--------------------------------------

	sub create_work_dir {
		my ($self) = @_;

		my $path = $self->work_dir;
		return unless $path;

		eval { make_path($path) };
		if ($@) {
			print STDERR "Couldn't create $path: $@", $/;
			return;
		}

		# also create the QC dir
		eval { make_path("$path/qc") };
		if ($@) {
			print STDERR "Couldn't create QC $path/qc: $@", $/;
			return;
		}

		return 1;
	}

	sub work_dir {
		my ($self) = @_;
		return unless ref $self eq __PACKAGE__ ;
		my $proj = $self->project;
		unless ($proj)  {
			confess "Project is missing...\n";
			return;
		}

		return File::Spec->catfile($self->config->{PROJECTS_DIR}, sprintf("%04X", $proj->id)); 	
	}

	#--------------------------------------
	# adds a set of files to the project
	# $pm->add_data([$file_details1, $file_details2, ..], $options)
	#
	sub add_data {
		#my ($self, $params, $options) = @_;
		my ($self, $params, $options) = @_;

		my (@errors, @warnings);

		my $bail_out = sub { return {errors => \@errors, warnings => \@warnings}};

		my $file_type = $params->{file_type} || '';

		my $_no_remote_check = defined $options ? $options->{_no_remote_check} : 0;
		if (!$_no_remote_check) {
			print STDERR  "__add_data__: Checking remote site to see if files exists.", $/ if $self->debug;
			my $io_api = $self->api_instance ? $self->api_instance->io : undef;
			if ($io_api) {
				my $files = $io_api->ls($params->{file_path});
				print STDERR Dumper( $files), $/;

				# TODO - what action should be taken when the file is not in the repository?
				unless (@$files) {
					print STDERR  "__add_data__: File not found in the iRODS repository: ", $params->{file_path}, $/;
				}
			}
		}
		else {
			print STDERR "__add_data__: Not checking if file exists.\n";
		}

		my $data_src = DataSource->insert ({
				project_id => $self->project,
				name => $params->{source} || '',
				note => $params->{source_note} || '',
			});
		return $bail_out->() unless $data_src;

		my $data_file = DataFile->create({
				project_id => $self->project,
				source_id => $data_src,
				file_name => $params->{file_name},
				file_path => $params->{file_path},
				file_type => $file_type,
				is_input => $params->{is_input} || 0,
			});
	}
	
	#--------------------------------------
	sub data {
		my ($self, %filters) = @_;

		my %allowed_filters = map {$_ => 1 } grep {!/^_|^project_id/} DataFile->columns;
		my %args = (
				project_id => $self->project->id,
			);
		for (keys %filters) {
			next unless defined $allowed_filters{$_} && defined $filters{$_};
			$args{$_} = $filters{$_};
		}
		DataFile->search(%args, {order_by => 'id'});
	}

	#--------------------------------------
	# returns status for two tasks: QC & trimming (later)
	sub qc_status {
		my ($self) = @_;
		my $project = $self->project;

		DataFile->get_qc_status($project);
	}
	#--------------------------------------
	sub do_qc {
		my ($self, $file_id) = @_;

		my $project = $self->project;

		my $app;
		my $st = $self->app("NGS_FASTQC");

		if ($st->{status} eq "success") {
			$app = $st->{app};
		} else {
			print STDERR  "NGS::do_QC::no NGS_FASTQC app found!!!", $/;
			return;
		}

		my $job_options = {
			archive => 'true',
			input => '',
			casava => 'false',
			jobName => '',
			format => 'fastq',
			#callbackUrl => 'ghiban@cshl.edu',
			nogroup => 'false',
		};

		my $data = $self->data(is_input => 1);
		my $qc_jobs = 0;
		while (my $f = $data->next) {
			next if $file_id && $file_id != $f->id;
			next if $f->qc_file_id;

			# set id, instead of file path so that we keep track of input files (in submit_job)
			$job_options->{input} = $f->id; 
			my $st = $self->submit_job($app->{conf}->{_task_name}, $app, $job_options);
			print STDERR 'do_QC: new job status: ', $st->{status}, $/ if $self->debug;
			if ($st->{status} eq 'success') {
				$qc_jobs++;
				my $mc_key = sprintf("ngs-%d-%s-%d", $self->project->id, "ngs_fastqc", $f->id);
				print STDERR "doQC/mc_key: ", $mc_key, $/ if $self->debug;
				$self->{_mc}->set($mc_key, 'pending', 7200);
			}
		}

		$qc_jobs;
	}
	#--------------------------------------
	sub auth {
		my ($self, $user, $token) = @_;
		print STDERR "user: $user \n token: $token \n" if $self->debug;
		my $api_instance = iPlant::FoundationalAPI->new(
			user => $user,
			token => $token,
			debug => $self->debug,
		);

		print STDERR "Can't auth.." unless $api_instance->auth, $/;
		if ($api_instance->token eq kExitError) {
			print STDERR "Can't authenticate!" , $/;
			return kExitError;
		}
		$self->api_instance($api_instance);
	}

	#--------------------------------------
	# returns an hash { status => '[fail|success]', message => '', app => $app},
	#	where $app is an instance of iPlant::FoundationalAPI::Object::Application
	#
	sub app {
		my ($self, $app_conf_file) = @_;

		unless ($app_conf_file) {
			return {status => 'fail', message => 'sub app: config file is missing the app id'};
		}

		my $app_cf = DNALC::Pipeline::Config->new->cf($app_conf_file);
		unless ($app_cf && $app_cf->{id}) {
			return {status => 'fail', message => 'sub app: config file is missing the specified app'};
		}

		my ($app_id, $app_name) = ($app_cf->{name}, $app_cf->{id});
		unless ($app_name) {
			$app_name = $app_cf->{id};
			$app_name =~ s/-[\d.]*$//;
		}

		print STDERR  ' + app_name = ', $app_name, $/;
		print STDERR  ' + app_id = ', $app_id, $/;

		my $api_instance = $self->api_instance;
		return {status => 'fail', message => 'sub app: no api_instance object'} unless $api_instance;

		my $app;

		my $app_ep = $api_instance->apps;
		my $apps = $app_ep->find_by_name($app_name);
		if (@$apps) {
			#print STDERR Dumper( $apps), $/;
			# get by id
			($app) = grep {$_->id eq $app_id} @$apps;

			# get by name
			unless ($app) {
				($app) = grep {$_->name eq $app_name} @$apps;
			}

			# get the 1st one
			$app ||= $apps->[0];

			# TODO : find a better name for the next method
			$self->apply_app_settings($app, $app_cf);

			return {status => 'success', app => $app };
		}

		# else ..
		print  STDERR "App $app_name not found sorry \n";
		return {status => 'fail', message => "Application $app_name not found"};
	}
	
	# apply our own configuration file for the app
	#	supply our own default values, or field labels, hide some of the fields
	sub apply_app_settings {
		my ($self, $app, $app_cf) = @_;


		#print STDERR  $app_cf->{id}, " eq ",  $app->id, $/;
		# do we want to make sure we have exact version of the app?!
		unless ($app_cf->{id} eq $app->id) {
			print STDERR  "Version mismatch for $app_cf->{id}: ", $app->id, $/;
			#return;
		}

		my $app_inputs = $app->inputs;
		my $app_params = $app->parameters;

		my %app_inputs = map {$_->{id} => $_} @$app_inputs;

		my @inputs = ();

		for my $cf_input (@{$app_cf->{inputs}}) {
			my $id = $cf_input->{id};
			next unless defined($app_inputs{$id});
			my $input = $app_inputs{$id};

			#next if $cf_input->{$id}->{hidden};
			$input->{hidden} = $cf_input->{hidden} if $cf_input->{hidden};
			$input->{display_type} = $cf_input->{display_type};
			$input->{value} = $cf_input->{value} if $cf_input->{value};
			$input->{label} = $cf_input->{label} if $cf_input->{label};

			push @inputs, $input;
		}

		$app->{inputs} = \@inputs if @inputs;

		my @params = ();
		my %app_params = map {$_->{id} => $_} @$app_params;
		#print STDERR Dumper( $app_cf->{parameters} ), $/;

		for my $cf_param (@{$app_cf->{parameters}}) {
			my $id = $cf_param->{id};
			next unless defined($app_params{$id});
			my $param = $app_params{$id};

			#next if $cf_input->{$id}->{hidden};
			$param->{hidden} = $cf_param->{hidden} if $cf_param->{hidden};
			$param->{display_type} = $cf_param->{display_type};
			$param->{value} = $cf_param->{value} if defined $cf_param->{value};
			$param->{label} = $cf_param->{label} if $cf_param->{label} ne '';

			push @params, $param;
		}
		$app->{parameters} = \@params if @params;
		$app->{conf} = $app_cf;
	}
	#--------------------------------------
	sub job {
		my ($self, $app_id, $form_arguments) = @_;
		
		my $api_instance = $self->api_instance;
		return {status => 'fail', message => 'sub job: no api_instance object'} unless $api_instance;
		
		my %job_arguments = %$form_arguments;
		my $apps = $api_instance->apps;
		my ($app) = $apps->find_by_name($app_id);
		print STDERR "APP: ", $app, $/;
		
		print STDERR "App ID: $app_id <br /> Annotation Field: $job_arguments{ANNOTATION} <br />";
		
		# adding additional 'hidden' arguments
		$job_arguments{jobName} = $app_id . '-DNAS-' . int(rand(100));
		$job_arguments{archive} = '1';
		$job_arguments{processors} = '1';
		$job_arguments{requested_time} = '11:11:11';
		$job_arguments{softwareName} = $app_id;
		
		print STDERR Dumper (%job_arguments);
		my $job_ep = $api_instance->job;
		my $job = $job_ep->submit_job($app, %job_arguments);
		#print STDERR "returned from submit_job: ", %$job, $/; 
	}

	sub submit_job {
		my ($self, $task_name, $app, $params) = @_;

		unless ($self->project) {
			return _error('Cannot submit job: project is missing!');
		}

		my $apif = $self->api_instance;
		unless ($apif) {
			return _error('API instance not set.');
		}

		# if there are the inputs with {display_type => 'show_files'}
		#	- basically we replace the file id's when we send the data to the API
		#	- we keep track of the replaced data, in case we hit an error
		my @input_files = ();
		for my $input (grep {defined $_->{display_type} && $_->{display_type} eq 'show_files'} @{$app->inputs}) {
			if (defined $params->{$input->{id}} && $params->{$input->{id}} =~ /^\d+$/) {
				my $input_file = DataFile->retrieve($params->{$input->{id}});
				next unless $input_file;

				# if we have a trimmed file for this selected file, make use of it!!
				my $tdf = $input_file->trimmed_file; #DataFile->retrieve($input_file->trimmed_file_id);
				$input_file = $tdf if $tdf;

				push @input_files, {
							app_input_id => $input->{id},
							file_id => $params->{$input->{id}},
							file_path => $input_file->file_path,
					};
				$params->{$input->{id}} = $input_file->file_path;
			}
		}

		# we need to get a response when the job finishes
		#$params->{callbackUrl} = 'http://summercamps.dnalc.org/payment_notify.html?payer_email=&txn_id=0&';
		print STDERR "ProjectManager::submit_job: params = ", Dumper($params), $/ if $self->debug;
		my $jobdb; #

		my $job_ep = $apif->job;
		my $job_st = $job_ep->submit_job($app, %$params);

		# this sux
		# revert the values of the input parameters we changed 20 lines above
		for my $if (@input_files) {
			 $params->{ $if->{app_input_id} } = $if->{file_id};
		}

		#print STDERR  "ProjectManager::submit_job: ", Dumper($job_st), $/;
		if ($job_st && $job_st->{status} eq "success") {
			my $api_job = $job_st->{data};


			#print STDERR  Dumper($self->{task_name_to_id}), $/;
			print STDERR  '**App name: ', $app->name, $/;

			$jobdb = eval {DNALC::Pipeline::NGS::Job->create({
						api_job_id => $api_job->{id},
						project_id => $self->project,
						user_id => $self->project->user_id,
						task_id => $self->{task_name_to_id}->{ $task_name },  # TODO - check if task exists
						status_id => $status_map{processing},
					});
				};
			if ($@) {
				my $msg = $@;
				print STDERR  "Error: ", $msg, $/;
				return _error($msg);
			}
			else {

				# cache status
				#my $mc_key = sprintf("ngs-%d-%s", $self->project->id, $app->id);

				# add input files to the job object
				for my $if (@input_files) {
					$jobdb->add_to_input_files({
							file_id => $if->{file_id},
							project_id => $self->project,
							app_input_id => $if->{app_input_id},
						});
					#$mc_key .= '-' . $if->{file_id};
				}

				# keep track of this job, so that we can check it's status
				$self->track_job({ job => $jobdb, token => $self->api_instance->token});

				# store job parameters that were used
				my @params = ();
				for my $type (qw/inputs parameters/) {
					my $sg_type = $type; $sg_type =~ s/s$//;
					for (@{$api_job->{$type}}) {
						my ($name, $value) = each %$_;
						eval {
							$jobdb->add_to_job_params({type => $sg_type, name => $name, value => $value || ''});
						};
					}
				}

				print STDERR  'TODO: move job_params to NGS::Job', $/;
				# add the rest of the job parameters
				for my $name (sort keys %$api_job) {
					next if $name =~ /^(?:inputs|parameters|status)$/;

					my $value = $api_job->{$name} || '';
					if (ref($value) eq 'ARRAY') {
						next if ref($value->[0]); # can't handle all situations
						$value = join ":", @$value;
					}
					$jobdb->add_to_job_params({type => '', name => $name, value => $value});
				}
			}
			return {status => 'success', data => $jobdb};
		}
		else {
			_error($job_st ? $job_st->{message} : 'Could not submit job.', $job_st ? $job_st->{data} : undef);
		}
	}

	#--------------------------------------
	sub get_jobs_by_task {
		my ($self, $task, $show_deleted) = @_;

		$show_deleted ||= 0;

		$show_deleted 
			? DNALC::Pipeline::NGS::Job->search(
					task_id => $self->{task_name_to_id}->{$task}, 
					project_id => $self->project, { order_by=>'id' })
			: DNALC::Pipeline::NGS::Job->search(
					task_id => $self->{task_name_to_id}->{$task}, 
					project_id => $self->project,
					deleted => 0, { order_by=>'id' });
	}

	#--------------------------------------
	sub get_job_by_id {
		my ($self, $job_id) = @_;
		
		DNALC::Pipeline::NGS::Job->retrieve($job_id);
	}

	#--------------------------------------
	sub track_job {
		my ($self, $p) = @_;
		my $job = $p->{job};

 		my $jt = eval {
				JobTrack->create({
					job_id => $job,
					api_job_id => $job->api_job_id,
					user_id => $job->user_id,
					token => $p->{token},
					api_status => 'PENDING',
					tracker_status => '',
				});
 			};
 		if ($@) {
 			print STDERR  "track_job: Unable to add tracker for job: ", $job, "\n", $!, "\n", $/;
 			print STDERR  $!, $/;
 		}
 		else {
 			print STDERR  "jt = ", $jt, $/;
 		}
	}
	#--------------------------------------
	sub search {
		my ($self, %args) = @_;
		Project->search(%args);
	}

	#---------------------------------------
	sub debug {
		my ($self, $debug) = @_;

		if (defined $debug) {
			$self->{debug} = $debug;
		}

		$self->{debug};
	}

	#---------------------------------------
	sub project {
		my ($self, $project) = @_;

		if ($project) {
			$self->{project} = $project;
		}

		$self->{project};
	}

	#---------------------------------------
	sub project_genome_path {
		my ($self) = @_;

		my $org = $self->project->organism;

		my $genomes = DNALC::Pipeline::Config->new->cf('NGS_GENOMES');
		my $genome_data = $genomes->{genomes}->{$org};
		my $path = $genomes->{store} . '/' . $org . '/' . $genome_data->{sub_part} 
			. '/' . $genome_data->{versions}->[0] . '/genome.fas';

		return $path;
	}

	#---------------------------------------
	sub project_annotation_path {
		my ($self) = @_;

		my $annotaion = $self->project_genome_path;
		$annotaion =~ s/genome\.fas$/annotation.gtf/;

		return $annotaion;
	}
	#--------------------------------------
	sub api_instance {
		my ($self, $api_instance) = @_;

		if ($api_instance) {
			$self->{api_instance} = $api_instance;
		}

		$self->{api_instance};
	}

	#--------------------------------------
	# returns status for these routines: tophat, cufflinks, cuffdiff
	sub get_status {
		my ($self) = @_;

		## TODO - use memcached

		# $running_jobs is a hashref like
		# {
		#	'ngs_tophat' => { 'done' => '1', 'error' => '2' },
		#	'ngs_fastqc' => { 'done' => '1' },
		# }

		my $running_jobs = Job->get_jobs_status($self->project, $self->{task_name_to_id}->{ngs_tophat});

		my %stats = map {$_ => 'disabled'} keys %{$self->{task_name_to_id}};

		#	we need at least one input file (fastq)
		my @data = $self->data(is_input => 1);

		# fastqc
		for (qw/processing done not-processed/) {
			last unless @data;
			if (exists $running_jobs->{ngs_fastqc}->{$_}) {
				$stats{ngs_fastqc} = $_;
				last;
			}
		}

		# tophat
		$stats{ngs_tophat} = @data ? 'not-processed' : 'disabled';
		if ($stats{ngs_tophat} ne 'disabled') {
			if ($running_jobs->{ngs_tophat}->{processing}) {
				$stats{ngs_tophat} = 'processing';
			}
			elsif ($running_jobs->{ngs_tophat}->{done} || $running_jobs->{ngs_tophat}->{error}) {
				$stats{ngs_tophat} = 'done';
			}
		}

		# cufflinks
		unless ( defined $running_jobs->{ngs_cufflinks}) {
			if ($running_jobs->{ngs_tophat} && exists $running_jobs->{ngs_tophat}->{done}) {
				$stats{ngs_cufflinks} = 'not-processed';
			}
		}
		else {
			if ($running_jobs->{ngs_cufflinks}->{processing}) {
				$stats{ngs_cufflinks} = 'processing';
			}
			elsif ($running_jobs->{ngs_cufflinks}->{done} || $running_jobs->{ngs_cufflinks}->{error}) {
				$stats{ngs_cufflinks} = 'done';
			}
		}

		# cuffdiff
		unless ( defined $running_jobs->{ngs_cuffdiff}) {
			if ($running_jobs->{ngs_tophat} && $running_jobs->{ngs_tophat}->{done} > 1) {
				$stats{ngs_cuffdiff} = 'not-processed';
			}
		}
		else {
			if ($running_jobs->{ngs_cuffdiff}->{processing}) {
				$stats{ngs_cuffdiff} = 'processing';
			}
			elsif ($running_jobs->{ngs_cuffdiff}->{done} || $running_jobs->{ngs_cuffdiff}->{error}) {
				$stats{ngs_cuffdiff} = 'done';
			}
		}
	

		# cuffmerge
		# TODO

		%stats;
	}

	#--------------------------------------
	#sub set_status {
	#	my ($self, $app_id, $status, @input_files) = @_;
	#}
	#--------------------------------------
	sub remove_project {
		my ($self) = @_;
		my $p = $self->project;
		my $user_id = $p->user_id;

		# project dir
		my $dir = $self->work_dir;

		DNALC::Pipeline::App::Utils->remove_dir($dir);

		print STDERR  ' ?? Should we remove the iRODS files generated by this project?', $/;
		print STDERR  ' ?? Should we kill any unfinnished jobs in the API?', $/;

		my $mp = $p->master_project;
		$mp->public(0);
		$mp->archived(1);
		my $rc = $mp->update;
		unless ($rc) {
			#$self->log("ERROR: Unable to remove NGS project $p", type => 'ERR', user_id => $user_id);
			print STDERR  "ERROR: Can't remove NGS project ", $p->id, $/;
		}
		$rc
	}
	#--------------------------------------
	sub _error {
		my ($self, $msg, $data) = @_;
		if (!ref($self)) {
			$data = $msg;
			$msg = $self;
		}

		return {status => 'error', message => $msg || 'Unspecified error.', data => $data};
	}
	#--------------------------------------
	#--------------------------------------
	# job/task specific routines

	#--------------------------------------
	# default task handler
	sub task_handle_default {
		my ($self, $job, $api_files) = @_;

		my $src_id;
		my $task = $job->task_id->name;
		my $app_conf = DNALC::Pipeline::Config->new->cf(uc $task);

		return unless @$api_files;

		# create a data_source_file entry
		#
		my $job_name = $job->attrs->{name};
		$src_id = DNALC::Pipeline::NGS::DataSource->create({
					project_id => $job->project_id,
					name => 'Output from ' . $task,
					note => $job_name || '',
				});
		if ($!) {
			print STDERR 'Can\'t add source: ', $! , $/;
		}

		if ($src_id) {
			my $counter = 0;
			my $base_name = '';
			my @job_input_files = $job->input_files;
			if (@job_input_files == 1) {
				$base_name = $job_input_files[0]->file->file_name;
				$base_name =~ s/\.(.*?)$//;
			}

			for my $df (@$api_files)  {
				my ($file_type) = $df->path =~ /\.(.*?)$/;
				my $fname = $df->name;

				# keep the same basename for the file
				if ($app_conf->{_propagate_input_file_name}) {
					if ($base_name) {
						$fname = $base_name . sprintf("%s.%s", $counter > 1 ? $counter : '', $fname =~ /\.(.*?)$/);
					}
				}

				print STDERR  'output file: ', $fname, $/ if $self->debug;
				my $data_file = DNALC::Pipeline::NGS::DataFile->create({
						project_id => $job->project_id,
						source_id => $src_id,
						file_name => $fname,
						file_path => $df->path,
						file_type => $file_type || '',
					});
				if ($data_file) {
					my $outfile = DNALC::Pipeline::NGS::JobOutputFile->create({
							file_id => $data_file,
							job_id => $job,
							project_id => $job->project_id,
						});
				}
				$counter++;
			}
		} # end if($src_id)

	}
	#--------------------------------------
	#
	sub task_handle_tophat_output {
		my ($self, $job, $api_files) = @_;

		return unless @$api_files;

		my $src_id;
		my $task = $job->task_id->name;
		my $app_conf = DNALC::Pipeline::Config->new->cf(uc $task);

		$self->task_handle_default($job, $api_files);

		# create a data_source_file entry
		#
		my $job_name = $job->attrs->{name};
		$src_id = DNALC::Pipeline::NGS::DataSource->create({
					project_id => $job->project_id,
					name => substr(sprintf('Local files from %s', $task), 0, 32),
					note => sprintf("%d/%s", $job->id, $job_name || ''),
				});
		if ($!) {
			print STDERR 'Can\'t add source: ', $! , $/;
		}


		my $dest_dir = File::Spec->catfile($self->work_dir, "tophat");
		unless (-d $dest_dir) {
			unless (make_path($dest_dir)) {
				print STDERR  " oo unable to create TH directory: ", $!, $/;
			}
		}

		print STDERR  " -- dest dir: ", $dest_dir, $/ if $self->debug;

		if ($src_id) {
			my $counter = 0;
			my $base_name = '';
			my @job_input_files = $job->input_files;
			if (@job_input_files == 1) {
				$base_name = $job_input_files[0]->file->file_name;
				$base_name =~ s/\.(.*?)$//;
			}

			# download the files
			#
			my $io = $self->api_instance->io;

			for my $df (@$api_files)  {
				my ($file_type) = $df->path =~ /\.(.*?)$/;
				my $fname = $df->name;

				# keep the same basename for the file
				if ($app_conf->{_propagate_input_file_name}) {
					if ($base_name) {
						$fname = $base_name . sprintf("%s.%s", $counter > 1 ? $counter : '', $fname =~ /\.(.*?)$/);
					}
				}

				my $save_to_file = File::Spec->catfile($dest_dir, sprintf("%d.%s", $job, $fname));
				if ($io) {
					unless (-f $save_to_file) {
						my $data = $io->stream_file($df->path, save_to => $save_to_file);
						print STDERR  " oo saved: ", $data, " ", $save_to_file, $/;
					}
				}


				if (-f $save_to_file) {
					print STDERR  'output file: ', $fname, $/ if $self->debug;
					my $data_file = DNALC::Pipeline::NGS::DataFile->create({
							project_id => $job->project_id,
							source_id => $src_id,
							file_name => $fname,
							file_path => $save_to_file,
							file_type => $file_type || '',
							is_local => 1,
						});
					if ($data_file) {
						my $outfile = DNALC::Pipeline::NGS::JobOutputFile->create({
								file_id => $data_file,
								job_id => $job,
								project_id => $job->project_id,
							});
					}
					$counter++;
				}
			} # end for (@$api_files)
		} # end if($src_id)

	}

	#--------------------------------------
	# TODO this method should be incorporated into task_handle_default
	#		a parameter in the config should determine if the output files should be downloaded or not.
	sub task_handle_cufflinks_output {
		my ($self, $job, $api_files) = @_;

		return unless @$api_files;

		my $src_id;
		my $task = $job->task_id->name;
		my $app_conf = DNALC::Pipeline::Config->new->cf(uc $task);

		$self->task_handle_default($job, $api_files);

		# create a data_source_file entry
		#
		my $job_name = $job->attrs->{name};
		$src_id = DNALC::Pipeline::NGS::DataSource->create({
					project_id => $job->project_id,
					name => substr(sprintf('Local files from %s', $task), 0, 32),
					note => sprintf("%d/%s", $job->id, $job_name || ''),
				});
		if ($!) {
			print STDERR 'Can\'t add source: ', $! , $/;
		}


		my $dest_dir = File::Spec->catfile($self->work_dir, $task);
		unless (-d $dest_dir) {
			unless (make_path($dest_dir)) {
				print STDERR  " oo unable to create $task directory: ", $!, $/;
			}
		}

		print STDERR  " -- dest dir: ", $dest_dir, $/ if $self->debug;

		if ($src_id) {
			my $counter = 0;
			my $base_name = '';
			my @job_input_files = $job->input_files;
			if (@job_input_files == 1) {
				$base_name = $job_input_files[0]->file->file_name;
				$base_name =~ s/\.(.*?)$//;
			}

			# download the files
			#
			my $io = $self->api_instance->io;

			for my $df (@$api_files)  {
				my ($file_type) = $df->path =~ /\.(.*?)$/;
				my $fname = $df->name;

				# keep the same basename for the file
				if ($app_conf->{_propagate_input_file_name}) {
					if ($base_name) {
						$fname = $base_name . sprintf("%s.%s", $counter > 1 ? $counter : '', $fname =~ /\.(.*?)$/);
					}
				}

				my $save_to_file = File::Spec->catfile($dest_dir, sprintf("%d.%s", $job, $fname));
				if ($io) {
					unless (-f $save_to_file) {
						my $data = $io->stream_file($df->path, save_to => $save_to_file);
						print STDERR  " oo saved: ", $data, " ", $save_to_file, $/;
					}
				}


				if (-f $save_to_file) {
					print STDERR  'output file: ', $fname, $/ if $self->debug;
					my $data_file = DNALC::Pipeline::NGS::DataFile->create({
							project_id => $job->project_id,
							source_id => $src_id,
							file_name => $fname,
							file_path => $save_to_file,
							file_type => $file_type || '',
							is_local => 1,
						});
					if ($data_file) {
						my $outfile = DNALC::Pipeline::NGS::JobOutputFile->create({
								file_id => $data_file,
								job_id => $job,
								project_id => $job->project_id,
							});
					}
					$counter++;
				}
			} # end for (@$api_files)
		} # end if($src_id)

	}
	#--------------------------------------
	#
	sub task_handle_trimmed_file {
		my ($self, $job, $api_files) = @_;

		# one input file for this task
		my ($job_input_file) = ($job->input_files);

		my $task_name = $self->{task_id_to_name}->{$job->{task_id}};
		#my $data_src = DataSource->insert ({
		#		project_id => $self->project,
		#		name => join('/', 'job', $job->id, $task_name),
		#		note => '',
		#	});

		#my @project_files = $self->data;
		for my $f (@$api_files) {
			my $file_path = $f->path;

			my $file_name = basename($file_path);
			$file_name =~ s/fastx_trimmer_(.*?)\.fastq/$1_trimmed.fastq/;

			my $tdf = $self->add_data({
						source => join('/', 'job', $job->id, $task_name),
						file_name => $file_name,
						file_path => $file_path,
						file_type => 'fastq',
					},
					{_no_remote_check => 1},
				);

			if ($tdf) {
				my $if = $job_input_file->file;
				$if->trimmed_file_id($tdf);
				$if->update;

				my $mc_key = sprintf("ngs-%d-%s-%d", $self->project->id, "fastx_trimmer-0.0.13", $if->id);
				$self->{_mc}->set($mc_key, '', 1);
			}
		}
	}

	#--------------------------------------
	sub task_handle_qc {
		my ($self, $job, $api_files) = @_;

		my @ifiles = $job->input_files;
		#print STDERR Dumper( \@ifiles), $/;

		# one input file for this task
		#amy ($job_input_file) = map {$_->{value}} $job->input_files;
		my ($job_input_file) = ($job->input_files);

		#print STDERR  "** > ", $job_input_file, $/;

		my $working_dir =$self->work_dir;
		my $qc_dir = File::Spec->catfile($working_dir, 'qc');
		unless (-d $qc_dir) {
			mkdir $qc_dir, 0777 or print STDERR "Unable to create QCDir: ", $qc_dir, $/;
		}

		my ($archive) = grep {/\.zip$/ } map {$_->path} @$api_files;

		my $save_to = File::Spec->catfile($qc_dir, sprintf("%d-QC-%s", $job->id, $job_input_file->file->file_name));
		my $save_to_file = sprintf("%s.zip", $save_to);

		my $io = $self->api_instance->io;
		if ($io) {
			my $data = $io->stream_file($archive, save_to => $save_to_file);

			#print STDERR "dest: ", $save_to, $/;
			#print STDERR "data: ", $data, $/;

			my $html_file;
			if (-f $save_to_file) {
				
				my $zip = Archive::Zip->new;
				unless ( $zip->read( $save_to_file ) == AZ_OK ) {
					print STDERR  'ZIP read error';
					return;
				}
				my @members = grep {$_->fileName !~ m|/\._|} $zip->members;
				my ($root) = map {$_->fileName} grep {$_->fileName =~ m|_fastqc/$|} @members;

				#print STDERR 'root: ', $root, $/;

				mkdir($save_to);

				# extract files
				for (qw/Images Icons/) {
					mkdir File::Spec->catfile($save_to, $_);
				}

				for my $m (@members) {
					my $f = $m->fileName;
					$f =~ s/$root//;
					my $dest_f = File::Spec->catfile($save_to, $f);
					#print "\t", $f, $/;
					#print "\t", $dest_f, $/;
					$zip->extractMember($m, $dest_f);

					$html_file = $dest_f if $f =~ /fastqc_report\.html$/;
				}

			}

			if ($html_file && -f $html_file) {

				#print STDERR  "HTML_FILE: ", $html_file, $/;
				unlink $save_to_file; # remove the zip file

				# updated the input file of this job with this QC report associated to it

				# add the file
				my $hfile = $self->add_data({
							source => sprintf('QC data from job#%d',  $job),
							file_name => 'FastQC report',
							file_path => $html_file,
							file_type => 'html',
							is_local => 1,
						},
						{_no_remote_check => 1}
					);

				if ($hfile) {
					my $ifile = $job_input_file->file;
					$ifile->qc_file_id($hfile);
					$ifile->update;

					my $mc_key_qc = sprintf("ngs-%d-%s-%d", $self->project->id, "ngs_fastqc", $ifile->id);
					#print STDERR  $mc_key_qc, $/;
					$self->{_mc}->set($mc_key_qc, '', 1);
				}
			}
		}
	}

}

1;
