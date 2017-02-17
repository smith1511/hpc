
Param(
  [string]$namdConfFilePath = "mdff-domain\\domain-step1.namd",
  [string]$namdArgs = "",
  [string]$recipe = "NAMD-TCP"
)

if (-Not (Test-Path $namdConfFilePath))
{
    Write-Host "No such file $namdConfFilePath"
    exit 1
}

$jobId = "namd-" + [guid]::NewGuid().ToString()
$rootDir = "$PSScriptRoot"
$tmpDir = "$rootDir\\.shipyard_tmp\\$jobId"
$tmpInputsDir = "$tmpDir\\inputs"
$shipyardDir = "$rootDir\\shipyard\\recipes\\$recipe"

$namdConfFile = Split-Path $namdConfFilePath -leaf
$namdInputDir = (get-item $namdConfFilePath).Directory.FullName

mkdir "$tmpInputsDir" | out-null

# Copy the input files
Copy-Item -Path "$namdInputDir\\*" -Destination "$tmpInputsDir" -Recurse

# Copy the helper scripts
Copy-Item -Path "$rootDir\\Scripts\\*" -Destination "$tmpInputsDir" -Recurse

# Copy the shipyard configs and replace and variables needed
$shipyardFilesToCopy = "$shipyardDir\\config\\credentials.json","$shipyardDir\\config\\config.json","$shipyardDir\\config\\jobs.json","$shipyardDir\\config\\pool.json"
foreach ($file in $shipyardFilesToCopy)
{
    $filename = Split-Path $file -leaf
    $destination = "$tmpDir\\$filename"
    $sourcePath = $tmpInputsDir -replace "\\", "/"
    get-content $file | foreach-object {
		$_ -replace "@JOB_ID@", "$jobId" `
		   -replace "@SOURCE_PATH@", "$sourcePath" `
		   -replace "@NAMD_INPUT_FILE@", "$namdConfFile" `
           -replace "@NAMD_ARGS@", "$namdArgs" } | set-content $destination
}

Write-Host "Uploading job inputs..."
$output = & $env:python $env:shipyard data ingress --configdir "$tmpDir" 2>&1
if ($lastexitcode -ne 0)
{
    Write-Host "Failed to upload input data"
    Write-Host $output
    exit 1
}

Write-Host "Submitting job $jobId..."
& $env:python $env:shipyard jobs add --configdir "$tmpDir" --yes --tail stdout.txt
if ($lastexitcode -ne 0)
{
    Write-Host "Failed to submit job"
    exit 1
}

Write-Host "Downloading job outputs..."
$output = & $env:python $env:shipyard data getfile --configdir "$tmpDir" --all --filespec "$jobId,dockertask-00000,std*.txt" 2>&1
if ($lastexitcode -ne 0)
{
	Write-Host $output
    Write-Host "Failed to retrieve outputs"
}

$output = & $env:python $env:shipyard data getfile --configdir "$tmpDir" --all --filespec "$jobId,dockertask-00000,wd/*" 2>&1
if ($lastexitcode -ne 0)
{
    Write-Host $output
	Write-Host "Failed to retrieve outputs"
    exit 1
}

Remove-Item $tmpInputsDir -Force -Recurse | out-null

exit 0
