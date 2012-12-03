use strict;
use warnings;
use Tk;
use Tk::widgets qw(JPEG);
use Tk::DialogBox;
use Tk::LabEntry;
use Image::Grab;
use Tk::NoteBook;

my (
	$coordinateFileName,    # name of the coordinate input file
	$saveFileName,          # name of the save file
	$loadedSaveFileName,    # name of the previous save file
	$comparisonFileName,    # name of the comparison input file
	$urlFileName,           # name of the file where the URL is saved
	$imageLabel,            # handle to the image display area
	$nameLabel,             # handle to the name display area
	$urlEntry,              # handle to the url display area
	$msgLabel,              # handle to the message display area
	$backButton,            # handle to the back button in the menu
	$resumeButton,          # handle to the resume button in the menu
	$searchWindow,          # handle to the Tk::Toplevel instance that contains the search window
	$searchButton,          # handle to the search button in the menu
	$resetButton,           # handle to the reset button in the menu
	$defaultBGColor,        # system default color for the label widget
	$tmpFileName,           # name of file where current image binary is located
	$scaleIndex,            # zoom scale (1 to 10)
	$comparisonMode,        # boolean flag to determine if in comparison mode
	$done,                  # boolean flag to determine if no more classifications are to be done
	$classification,        # current classification selected by the user
	$objectListIsDirty,     # boolean flag to determine if list has been updated
	@objectsToClassify,     # list of objects to classify
	$curObjectIndex,        # index to the current object being displayed
	$imageURL,              # URL for fetching the image to display
	$sdssSite,              # SDSS DR7 image tool URL
	$mw,                    # handle to a Tk::MainWindow
	$hasBegun,              # flag to determine if classification has begun
	$invertColorsOpt,		# pass the "invert color" option to the SDSS DR7 ImageTool
	$labelOpt,				# pass the "label" option to the SDSS DR7 ImageTool
	$gridOpt,				# pass the "grid" option to the SDSS DR7 ImageTool
);

$tmpFileName       = '__tmp__.jpeg';
$scaleIndex        = 3;
$comparisonMode    = 0;
$done              = 0;
$objectListIsDirty = 0;
@objectsToClassify = ();
$curObjectIndex    = 0;
$hasBegun          = 0;
$imageURL          = 'http://casjobs.sdss.org/ImgCutoutDR7/getjpeg.aspx?width=512&height=341';
$sdssSite          = 'http://cas.sdss.org/astro/en/tools/chart/navi.asp?';
$invertColorsOpt = $labelOpt = $gridOpt = '';

$mw = MainWindow->new();
$mw->title('Galaxy Evolution Group Image Classifier');

# handle window closing with the quit function
$mw->protocol('WM_DELETE_WINDOW' => \&quit);

&setupMainWindow;

# bind the keyboard shortcuts
$mw->bind('<Control-Key-s>'       => \&saveToFile);
$mw->bind('<Control-Shift-Key-S>' => \&saveAs);
$mw->bind('<Control-Key-q>'       => \&quit);
$mw->bind('<Control-Key-b>'       => \&goBack);
$mw->bind('<Control-Key-r>'       => \&resume);
$mw->bind('<Control-Key-f>'       => \&openSearchWindow);
$mw->bind('<Key-space>'           => \&lazyClick);
$mw->bind('<Control-Key-u>'       => \&saveURL);

$defaultBGColor = $msgLabel->cget('-background');

MainLoop;

sub setImage
{
	return if ($done || !$hasBegun);

	my $curObjectRef = shift;

	my $pic   = new Image::Grab;
	my $image = undef;
	my ($name, $ra, $dec) = @{$curObjectRef}{'name', 'ra', 'dec'};

	my $url = $imageURL . '&opt=' . $invertColorsOpt.$labelOpt.$gridOpt .
			  '&ra=' . $ra . '&dec=' . $dec . '&scale=' . ($scaleIndex * 0.1);

	$pic->url($url);
	$pic->grab();

	if (defined $pic->image)
	{
		open($image, '>', $tmpFileName);
		print $image $pic->image;
		close $image;

		$image = $mw->Photo(-file => $tmpFileName);
		$imageLabel->configure(-image => $image);
	}
	else
	{
		$imageLabel->configure(-image => undef);
		&showError("No image found for $name at ($ra, $dec).");
		return;
	}

	$nameLabel->configure(-text => $name . '    (' . ($curObjectIndex + 1) . ' of ' . scalar @objectsToClassify . ')');

	$urlEntry->configure(-text => $sdssSite . 'ra=' . $ra . '&dec=' . $dec);

	$mw->update;
}

sub quit
{
	if ($objectListIsDirty)
	{
		return if (&promptForSave('quitting') != 0);
	}

	$mw->destroy();
	unlink $tmpFileName;
	exit;
}

sub reset
{
	return if ($resetButton->cget('-state') eq 'disabled' || ($objectListIsDirty && &promptForSave('resetting') != 0));

	($coordinateFileName, $saveFileName, $loadedSaveFileName, $comparisonFileName, $urlFileName) = (undef, undef, undef, undef, undef);
	($searchWindow, $scaleIndex) = (undef, 3);
	($comparisonMode, $done, $classification, $objectListIsDirty) = (0, 0, undef, 0);
	@objectsToClassify = ();
	$curObjectIndex    = 0;
	$hasBegun          = 0;

	&resetMessage;

	# if reset is called after a file load error before a 'Run' is selected, these won't work.
	$urlEntry->delete(0, 'end') if defined $urlEntry;
	$nameLabel->configure(-text => '') if defined $nameLabel;

	$mw->update;
}

sub promptForSave
{
	my $action = shift || 'continuing';

	my $response = $mw->messageBox(
		-message => "There is unsaved data.  Save before $action?",
		-title   => "Save before $action",
		-type    => 'yesnocancel',
		-icon    => 'question'
	);

	if ($response eq 'Yes')
	{
		return -1 if (&saveToFile != 0);
	}
	elsif ($response eq 'Cancel')
	{
		return -1;
	}
	elsif ($response eq 'No')
	{
		return 0;
	}

	return 0;
}

sub showWarning
{
	my $msg     = shift || 'error';
	my $isFatal = shift || 0;

	$msgLabel->configure(-text => $msg, -font => 'Helvetica 12 bold', -background => 'yellow');

	$done = 1 if $isFatal;
}

sub showError
{
	my $msg = shift || 'error';

	$msgLabel->configure(-text => $msg, -font => 'Helvetica 12 bold', -background => 'red');

	$done = 1;

	&deactivateNavigationButtons;

	# turn on reset in case $hasBegun == false
	$resetButton->configure(-state => 'active');
}

sub loadGeneralClassifierGrid
{
	my $parent = shift;
	my $row = 1;

	$parent->Radiobutton(
		-text     => 'spiral',
		-variable => \$classification,
		-value    => 's',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 1, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'elliptical',
		-variable => \$classification,
		-value    => 'e',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 3, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'peculiar (tails)',
		-variable => \$classification,
		-value    => 'pt',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 5, -columnspan => 2);

	$row++;

	$parent->Radiobutton(
		-text     => 'inclined disk',
		-variable => \$classification,
		-value    => 'id',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 1, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'elliptical+',
		-variable => \$classification,
		-value    => 'e+',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 3, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'unknown',
		-variable => \$classification,
		-value    => 'u',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 5, -columnspan => 2);

	$row++;

	$parent->Radiobutton(
		-text     => 'inner ring',
		-variable => \$classification,
		-value    => 'ir',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 1, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'peculiar',
		-variable => \$classification,
		-value    => 'p',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 3, -columnspan => 2);

	$parent->Radiobutton(
		-text     => 'merger',
		-variable => \$classification,
		-value    => 'm',
		-command  => \&classifyImage_Click
	)->grid(-sticky => 'nw', -row => $row, -column => 5, -columnspan => 2);
}

sub loadMergerClassifierGrid
{
	my $parent = shift;
	my $row = 1;

	$parent->Radiobutton(
        -text     => 'merger',
        -variable => \$classification,
        -value    => 'm',
        -command  => \&classifyImage_Click
    )->grid(-sticky => 'nw', -row => $row, -column => 1, -columnspan => 2);

    $parent->Radiobutton(
        -text     => 'contaminant',
        -variable => \$classification,
        -value    => 'c',
        -command  => \&classifyImage_Click
    )->grid(-sticky => 'nw', -row => $row, -column => 3, -columnspan => 2);

    $parent->Radiobutton(
        -text     => 'wet remnant',
        -variable => \$classification,
        -value    => 'w',
        -command  => \&classifyImage_Click
    )->grid(-sticky => 'nw', -row => $row, -column => 5, -columnspan => 2);
   
    $parent->Radiobutton(
        -text     => 'dry remnant',
        -variable => \$classification,
        -value    => 'd',
        -command  => \&classifyImage_Click
    )->grid(-sticky => 'nw', -row => $row, -column => 7, -columnspan => 2);
}

sub setupClassifierGrid
{
	my $row = 18;
	
	my $tabs = $mw->NoteBook()->grid('-sticky' => 'ew', '-row' => $row, '-column' => 1, '-columnspan' => 10);
	
	my $tabRef = $tabs->add('General', '-label' => 'General');
	$tabs->pageconfigure('General', '-createcmd' => [\&loadGeneralClassifierGrid, $tabRef]);
	
	$tabRef = $tabs->add('Mergers', '-label' => 'Mergers');
	$tabs->pageconfigure('Mergers', '-raisecmd' => [\&loadMergerClassifierGrid, $tabRef]);

	$mw->Label(-text => '')->grid(-row => ++$row, -rowspan => 2);

	$row += 3;

	$mw->Label(-text => 'Zoom:')->grid(-sticky => 'ew', -row => $row, -column => 1);

	$mw->Button(
		-text    => 'In',
		-width   => 4,
		-command => [\&zoom, 'in']
	)->grid(-sticky => 'e', -row => $row, -column => 2);

	$mw->Button(
		-text    => 'Out',
		-width   => 4,
		-command => [\&zoom, 'out']
	)->grid(-sticky => 'w', -row => $row, -column => 3);

	$mw->Checkbutton(
		'-text' => 'invert',
		'-onvalue' => 'I',
		'-offvalue' => '',
		'-variable' => \$invertColorsOpt,
		'-command' => \&setupImage
	)->grid(-sticky => 'w', -row => $row, -column => 4);
	
	$mw->Checkbutton(
		'-text' => 'label',
		'-onvalue' => 'L',
		'-offvalue' => '',
		'-variable' => \$labelOpt,
		'-command' => \&setupImage
	)->grid(-sticky => 'w', -row => $row, -column => 6);
	
	$mw->Checkbutton(
		'-text' => 'grid',
		'-onvalue' => 'G',
		'-offvalue' => '',
		'-variable' => \$gridOpt,
		'-command' => \&setupImage
	)->grid(-sticky => 'w', -row => $row, -column => 8);

	$mw->Label(-text => '')->grid(-row => ++$row, -rowspan => 3);

	$row += 4;

	$mw->Label(-text => 'URL:')->grid(-sticky => 'ew', -row => $row, -column => 1);

	$urlEntry = $mw->Entry(
		-text  => '',
		-font  => 'Helvetica 8',
		-width => 75
	)->grid(-sticky => 'nw', -row => $row, -column => 1, -columnspan => 10);
}

sub setupMainWindow
{
	$mw->configure(-menu => my $menubar = $mw->Menu);

	my $file = $menubar->cascade(-label => 'File',     -tearoff => 0);
	my $run  = $menubar->cascade(-label => 'Run',      -tearoff => 0);
	my $nav  = $menubar->cascade(-label => 'Navigate', -tearoff => 0);

	#	my $help = $menubar->cascade(-label => 'Help ',    -tearoff => 0);

	my $runClassify = $run->cascade(-label => 'Classify', -tearoff => 0);
	my $runCompare  = $run->cascade(-label => 'Compare',  -tearoff => 0);

	$file->command(
		-label     => 'Load coords',
		-underline => -1,
		-command   => \&promptForCoordinateFileName
	);

	$file->separator;

	$file->command(
		-label     => 'Load previous save',
		-underline => -1,
		-command   => \&promptForLoadedSaveFileName
	);

	$file->command(
		-label     => 'Load comparison',
		-underline => -1,
		-command   => \&promptForComparisonFileName
	);

	$file->separator();

	$file->command(
		-label       => 'Save',
		-accelerator => 'ctrl-s',
		-command     => \&saveToFile
	);

	$file->command(
		-label       => 'Save As',
		-accelerator => 'ctrl-shift-s',
		-command     => \&saveAs
	);

	$file->separator;

	# workaround for Macs not being able to copy/paste the text
	# out of the URL box.
	$file->command(
		-label       => 'Save URL',
		-accelerator => 'ctrl-u',
		-underline   => -1,
		-command     => \&saveURL
	);

	$file->separator;

	$file->command(
		-label       => 'Quit',
		-accelerator => 'ctrl-q',
		-underline   => -1,
		-command     => \&quit
	);

	$runClassify->command(
		-label     => 'New',
		-underline => -1,
		-command   => \&runClassifyNew
	);

	$runClassify->command(
		-label     => 'Continue',
		-underline => -1,
		-command   => \&runClassifyContinue
	);

	$runCompare->command(
		-label     => 'New',
		-underline => -1,
		-command   => \&runComparisonNew
	);

	$runCompare->command(
		-label     => 'Continue',
		-underline => -1,
		-command   => \&runComparisonContinue
	);

	$run->separator;

	$resetButton = $run->command(
		-label     => 'Reset',
		-underline => -1,
		-command   => \&reset,
		-state     => 'disabled'
	);

	$backButton = $nav->command(
		-label       => 'Back',
		-underline   => -1,
		-state       => 'disabled',
		-accelerator => 'ctrl-b',
		-command     => \&goBack
	);

	$resumeButton = $nav->command(
		-label       => 'Resume',
		-underline   => -1,
		-state       => 'disabled',
		-accelerator => 'ctrl-r',
		-command     => \&resume
	);

	$searchButton = $nav->command(
		-label       => 'Search',
		-underline   => -1,
		-command     => \&openSearchWindow,
		-accelerator => 'ctrl-f',
		-state       => 'disabled'
	);

	#	$help->command(
	#		-label     => 'Help',
	#		-underline => -1,
	#		-state     => 'disabled'
	#	);
	#
	#	$help->separator;
	#
	#	$help->command(
	#		-label     => 'About',
	#		-underline => -1,
	#		-state     => 'disabled'
	#	);

	my $imageFrame = $mw->Frame->grid(-sticky => 'nw', -row => 1, -column => 1, -columnspan => 10, -rowspan => 10);
	$mw->geometry('550x650');
	$imageLabel = $imageFrame->Label()->grid();

	$nameLabel = $mw->Label(
		-text => '',
		-font => 'Helvetica 12'
	)->grid(-sticky => 'nw', -row => 15, -column => 1, -columnspan => 10);

	$msgLabel = $mw->Label(-text => '')->grid(-sticky => 'ew', -row => 16, -column => 1, -columnspan => 10);

	$mw->Label(-text => '')->grid(-row => 17);
}

sub runClassifyNew
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before starting a new classification.');
		return;
	}

	unless (defined $coordinateFileName)
	{
		&showWarning('No coordinate file loaded!');
		return;
	}

	return if (&readCoordinateFile != 0);

	$hasBegun = 1;

	&setupClassifierGrid;
	&resetMessage;
	&activateNavigationButtons;
	&setupImage;
}

sub runClassifyContinue
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before starting a new classification.');
		return;
	}

	unless (defined $coordinateFileName)
	{
		&showWarning('No coordinate file loaded!');
		return;
	}

	unless (defined $loadedSaveFileName)
	{
		&showWarning('No save file loaded!');
		return;
	}

	return unless (&readCoordinateFile == 0 && &readLoadedSaveFile == 0);

	my $found = &findLastClassified;

	if ($found < 0)
	{
		&showWarning('All objects have been classified.');
		return;
	}
	else
	{
		$curObjectIndex = $found;
	}

	$hasBegun = 1;

	&setupClassifierGrid;
	&resetMessage;
	&activateNavigationButtons;
	&setupImage;
}

sub runComparisonNew
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before starting a new comparison.');
		return;
	}

	unless (defined $coordinateFileName)
	{
		&showWarning('No coordinate file loaded!');
		return;
	}

	unless (defined $comparisonFileName)
	{
		&showWarning('No comparison file loaded!');
		return;
	}

	$comparisonMode = 1;

	return if (&readCoordinateFile != 0 || &readComparisonFile != 0);

	$hasBegun = 1;

	&setupClassifierGrid;
	&resetMessage;
	&activateNavigationButtons;
	&setupImage;
}

sub runComparisonContinue
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before starting a new comparison.');
		return;
	}

	unless (defined $coordinateFileName)
	{
		&showWarning('No coordinate file loaded!');
		return;
	}

	unless (defined $comparisonFileName)
	{
		&showWarning('No comparison file loaded!');
		return;
	}

	unless (defined $loadedSaveFileName)
	{
		&showWarning('No save file loaded!');
		return;
	}

	$comparisonMode = 1;

	return if (&readCoordinateFile != 0 || &readComparisonFile != 0 || &readLoadedSaveFile != 0);

	my $found = &findLastClassified;

	if ($found < 0)
	{
		&showWarning('All objects have been classified.', 1);
		return;
	}
	else
	{
		$curObjectIndex = $found;
	}

	$hasBegun = 1;

	&setupClassifierGrid;
	&resetMessage;
	&activateNavigationButtons;
	&setupImage;
}

sub findLastClassified
{
	my $found = 0;
	my $i     = 0;

	for (; $i < scalar @objectsToClassify; $i++)
	{
		unless (defined $objectsToClassify[$i]->{'classification'})
		{
			$found = 1;
			last;
		}
	}

	return $i if $found;

	return -1;
}

sub promptForCoordinateFileName
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before loading a new coordinate file.');
		return;
	}

	my $tmpCoordinateFileName = $mw->getOpenFile(-title => 'Load coordinate file');

	return unless (defined $tmpCoordinateFileName);

	$coordinateFileName = $tmpCoordinateFileName;
}

sub promptForComparisonFileName
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before loading a new comparison file.');
		return;
	}

	my $tmpComparisonFileName = $mw->getOpenFile(-title => 'Load comparison file');

	return unless (defined $tmpComparisonFileName);

	$comparisonFileName = $tmpComparisonFileName;
}

sub promptForLoadedSaveFileName
{
	if ($done || $hasBegun)
	{
		&showWarning('Reset before loading a new previous save.');
		return;
	}

	my $tmpLoadedSaveFileName = $mw->getOpenFile(-title => 'Load save file');

	return unless (defined $tmpLoadedSaveFileName);

	$loadedSaveFileName = $tmpLoadedSaveFileName;
}

sub saveAs
{
	return unless $hasBegun;

	my $tmpSaveFileName = $mw->getSaveFile(-title => 'Select save file');

	return unless (defined $tmpSaveFileName);

	$saveFileName = $tmpSaveFileName;

	&saveToFile;
}

sub readCoordinateFile
{
	my $fdCoordinateInput = undef;

	eval {open $fdCoordinateInput, '<', $coordinateFileName};

	if ($@)
	{
		&showError($@);
		return -1;
	}

	my ($name, $ra, $dec);

	while (my $line = <$fdCoordinateInput>)
	{
		chomp($line);
		next if ($line =~ m/^#/ || $line eq '');
		($name, $ra, $dec) = split(",", $line);

		&trim(\$name);
		&trim(\$ra);
		&trim(\$dec);

		unless (defined $name
			&& $name ne ''
			&& defined $ra
			&& $ra ne ''
			&& defined $dec
			&& $dec ne '')
		{
			&showError("Error in coordinate file on line $..");
			return -1;
		}

		push @objectsToClassify, {'name' => $name, 'ra' => $ra, 'dec' => $dec};
	}

	return 0;
}

sub readLoadedSaveFile
{

	# by default, make the save file the same as the one that was loaded
	$saveFileName = $loadedSaveFileName;

	my $fdLoadedSave = undef;

	eval {open $fdLoadedSave, '<', $loadedSaveFileName};

	if ($@)
	{
		&showError($@);
		return -1;
	}

	my ($name, $class, $found);

	while (my $line = <$fdLoadedSave>)
	{
		chomp($line);
		next if ($line =~ m/^#/ || $line eq '');
		($name, $class) = split(",", $line);

		unless (defined $name
			&& $name ne ''
			&& defined $class
			&& $class ne '')
		{
			&showError("Error in loaded save file on line $..");
			return -1;
		}

		&trim(\$name);
		&trim(\$class);

		for (my $i = 0; $i < scalar @objectsToClassify; $i++)
		{
			if ($objectsToClassify[$i]->{'name'} eq $name)
			{
				$objectsToClassify[$i]->{'classification'} = $class;
				$found = 1;
				last;
			}
		}

		if (!$found)
		{
			&showError("Could not find $name from save file in coordinate file.");
			return -1;
		}

		$found = 0;
	}

	return 0;
}

sub readComparisonFile
{
	my $fdComparison = undef;

	eval {open $fdComparison, '<', $comparisonFileName};

	if ($@)
	{
		&showError($@);
		return -1;
	}

	my ($name, $class, $found);

	$found = 0;

	while (my $line = <$fdComparison>)
	{
		chomp($line);
		next if ($line =~ m/^#/ || $line eq '');
		($name, $class) = split(",", $line);

		unless (defined $name
			&& $name ne ''
			&& defined $class
			&& $class ne '')
		{
			&showError("Error in comparison file on line $..");
			return -1;
		}

		&trim(\$name);
		&trim(\$class);

		for (my $i = 0; $i < scalar @objectsToClassify; $i++)
		{
			if ($objectsToClassify[$i]->{'name'} eq $name)
			{
				$objectsToClassify[$i]->{'prevClassification'} = $class;
				$found = 1;
				last;
			}
		}

		if (defined $name && !$found)
		{
			&showError("Could not find $name from comparison file in coordinate file.");
			return -1;
		}

		$found = 0;
	}

	return 0;
}

sub saveToFile
{
	unless ($objectListIsDirty)
	{
		return 0;
	}

	unless (defined $saveFileName)
	{
		$saveFileName = $mw->getSaveFile(-title => 'Select save file');
		return -1 unless (defined $saveFileName);
	}

	my $fdSave = undef;

	eval {open $fdSave, '>', $saveFileName};

	if ($@)
	{
		showWarning($@);
		return -1;
	}

	if ($comparisonMode)
	{
		print $fdSave '# name,class_new,class_old', "\n";

		map {
			if (defined $_->{'classification'})
			{
				print $fdSave join ",", @{$_}{'name', 'classification', 'prevClassification'};
				print $fdSave "\n";
			}
		} @objectsToClassify;
	}
	else
	{
		print $fdSave '# name,class', "\n";

		map {
			if (defined $_->{'classification'})
			{
				print $fdSave join ",", @{$_}{'name', 'classification'};
				print $fdSave "\n";
			}
		} @objectsToClassify;
	}

	close($fdSave);

	$objectListIsDirty = 0;

	return 0;
}

sub lazyClick
{
	return unless ($hasBegun && $comparisonMode);

	&classifyImage_Click;
}

sub classifyImage_Click
{
	return unless $hasBegun;

	$objectsToClassify[$curObjectIndex]->{'classification'} = $classification;
	$objectListIsDirty = 1;
	$curObjectIndex++;
	&resetMessage;
	&setupImage;
}

sub activateNavigationButtons
{
	$backButton->configure(-state => 'active');
	$resumeButton->configure(-state => 'active');
	$searchButton->configure(-state => 'active');
	$resetButton->configure(-state => 'active');
}

sub deactivateNavigationButtons
{

	# deactivate all buttons except the reset button
	$backButton->configure(-state => 'disabled');
	$resumeButton->configure(-state => 'disabled');
	$searchButton->configure(-state => 'disabled');
}

sub setupImage
{
	if ($done || !$hasBegun)
	{
		&showError('Reset before continuing.');
		return;
	}

	#	print Dumper(@objectsToClassify), "\n\n";

	if ($curObjectIndex >= scalar @objectsToClassify)
	{
		&showWarning('Reached end of coordinate file.');
		$curObjectIndex--;
		return;
	}

	if ($comparisonMode)
	{
		unless (defined $objectsToClassify[$curObjectIndex]->{'prevClassification'})
		{
			&showWarning($objectsToClassify[$curObjectIndex]->{'name'} . ': No comparison found.');
		}

		if (defined $objectsToClassify[$curObjectIndex]->{'classification'})
		{
			$classification = $objectsToClassify[$curObjectIndex]->{'classification'};
		}
		else
		{
			$classification = $objectsToClassify[$curObjectIndex]->{'prevClassification'};
		}
	}
	else
	{
		$classification = $objectsToClassify[$curObjectIndex]->{'classification'};
	}

	if (defined $classification && $classification eq "i")
	{
		$classification = "u";
	}

	$scaleIndex = 3;

	&setImage($objectsToClassify[$curObjectIndex]);
}

sub goBack
{
	return unless (!$done && $hasBegun && $backButton->cget('-state') ne 'disabled');

	if ($curObjectIndex > 0)
	{
		&resetMessage;
		$curObjectIndex--;
		&setupImage;
	}
	else
	{
		&showWarning('Reached beginning!');
	}
}

sub resume
{
	return if ($done || !$hasBegun || $resumeButton->cget('-state') eq 'disabled');

	my $found = &findLastClassified;

	if ($found < 0)
	{
		&showWarning('No more objects to classify.');
		return;
	}

	$curObjectIndex = $found;

	&resetMessage;
	&setupImage;
}

sub saveURL
{
	return unless (defined $urlEntry && $hasBegun);

	my $urlText = $urlEntry->get();
	return unless defined $urlText;

	my $fname = undef;

	unless (defined $urlFileName)
	{
		$fname = $mw->getSaveFile();

		if (defined $fname)
		{
			$urlFileName = $fname;
		}
		else
		{
			return;
		}
	}

	open(my $fd, '>>', $urlFileName);

	unless (defined $fd)
	{
		&showWarning("Can't open file $fname: $!.");
		return;
	}

	print $fd $urlText, "\n";

	close($fd);
}

sub openSearchWindow
{
	return unless (!$done && $hasBegun && $searchButton->cget('-state') ne 'disabled');

	my ($action, $searchName, $db, $result, $showErrorMsg, $entry) = ('', '', undef, undef, 0, undef);

	while (1)
	{
		$db = $mw->DialogBox(
			-title   => 'Search',
			-buttons => ['Search', 'Cancel']
		);

		$entry = $db->add(
			'LabEntry',
			-textvariable => \$searchName,
			-width        => 20,
			-label        => 'Name',
			-labelPack    => [-side => 'left']
		)->pack;

		$entry->focus();

		if ($showErrorMsg)
		{
			$db->add(
				'Label',
				-text       => "Couldn't find $searchName.",
				-font       => 'Helvetica 12 bold',
				-background => 'yellow'
			)->pack;
		}

		$action = $db->Show;

		last if (!defined $action || $action eq 'Cancel');
		next if $searchName eq '';

		$result = &findByName($searchName);

		if ($result == -1)
		{
			$showErrorMsg = 1;
			next;
		}
		else
		{
			&resetMessage;
			$curObjectIndex = $result;
			&setupImage;
			last;
		}
	}
}

sub findByName
{
	my $name = shift;

	for (my $i = 0; $i < scalar @objectsToClassify; $i++)
	{
		if ($objectsToClassify[$i]->{'name'} eq $name)
		{
			return $i;
		}
	}
	return -1;
}

sub zoom
{
	return if ($done || !$hasBegun);

	my $direction = shift;

	if ($direction eq 'in' && $scaleIndex > 0)
	{
		$scaleIndex--;
		&setImage($objectsToClassify[$curObjectIndex]);
	}
	elsif ($direction eq 'out' && $scaleIndex < 10)
	{
		$scaleIndex++;
		&setImage($objectsToClassify[$curObjectIndex]);
	}
}

sub resetMessage
{
	$msgLabel->configure(-text => '', -background => $defaultBGColor) if defined $msgLabel;
}

sub trim
{
	my $str = shift;

	if (ref $str eq 'SCALAR' && defined $$str)
	{
		$$str =~ s/^\s+//;
		$$str =~ s/\s+$//;
	}
}
