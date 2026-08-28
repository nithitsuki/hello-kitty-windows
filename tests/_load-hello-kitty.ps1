# Loads hello-kitty.ps1's functions WITHOUT running the top-level command
# dispatch (which would default to 'toggle'). Strips everything from the
# '# Main dispatch' marker onward, then evaluates the rest in this scope.
param(
    [string]$Root
)
$src = Get-Content (Join-Path $Root 'hello-kitty.ps1') -Raw
$idx = $src.IndexOf('# Main dispatch')
if ($idx -lt 0) { throw 'hello-kitty.ps1: Main dispatch marker not found' }
$src = $src.Substring(0, $idx)
Invoke-Expression $src