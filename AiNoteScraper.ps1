#Requires -Version 5.1

<#
.SYNOPSIS
    Processes .txt files in a folder, uses Google Gemini to identify notes (considering filename),
    generates structured JSON for each note via Gemini (using filename as title hint),
    adds default fields if missing, and appends them to a JSON file with an incrementing order.

.DESCRIPTION
    This script iterates through all .txt files within a specified folder and its subfolders.
    For each file, it reads the content and filename. It sends both to the Google Gemini API
    to determine if the content represents a note, using the filename as additional context.
    If identified as a note, it asks Gemini to generate a JSON object representing the note,
    structuring it based on the content, and suggesting the filename as a potential title.
    The file's last write time is used for the 'createdAt' field.
    Default values are added for 'status' (Open), 'priority' (Medium), and 'isPrivate' ($false) if not generated by Gemini.
    An 'order' field is added, incrementing sequentially starting from 0 for each note added during the script run.
    The generated JSON object is appended to a specified output JSON file.

.PARAMETER FolderPath
    The starting folder path to search for .txt files recursively.

.PARAMETER OutputJsonFile
    The path to the JSON file where identified notes will be stored (or appended).
    If the file exists, the script will load existing notes and append new ones.

.PARAMETER ApiKey
    Your Google AI Gemini API Key. IMPORTANT: Avoid hardcoding this in production scripts.

.PARAMETER AiModel
    (Optional) The specific Google Gemini model name to use for analysis and generation.
    Defaults to 'gemini-1.5-flash-latest'. Other options might include 'gemini-pro'.
	
.PARAMETER ApiDelaySeconds
    (Optional) The number of seconds to wait after processing each file (after its API calls are done)
    before starting the next file. Useful for preventing API rate limiting. Defaults to 5. Must be between 0 and 300.

.EXAMPLE
    .\ProcessNotesWithGemini.ps1 -FolderPath "C:\MyDocuments\Notes" -OutputJsonFile "C:\MyDocuments\processed_notes.json" -ApiKey "YOUR_API_KEY_HERE"

.EXAMPLE
    .\ProcessNotesWithGemini.ps1 -FolderPath "C:\Notes" -OutputJsonFile "notes.json" -ApiKey "YOUR_KEY" -AiModel "gemini-pro"

.NOTES
    Author: AI Assistant
    Date:   2024-08-16
    Requires Google Gemini API Key.
    API calls may incur costs.
    Ensure PowerShell version 5.1 or higher.
    Gemini's JSON output structure depends on its interpretation of the text and filename.
    'order' field starts from 0 for each execution of the script and applies only to newly added notes.
    Filename analysis is used for classification and as a title hint.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputJsonFile,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$AiModel = "gemini-1.5-flash-latest", # Default model
	
	[Parameter(Mandatory=$false)]
    [ValidateRange(0, 300)] # Allow 0 to 5 minutes delay
    [int]$ApiDelaySeconds = 5 # Default to 0 seconds (no explicit delay)
)

# --- Configuration ---
$geminiApiUrl = "https://generativelanguage.googleapis.com/v1beta/models/$AiModel`:generateContent?key=$ApiKey"
$maxRetries = 2
$retryDelaySeconds = 5
# --- End Configuration ---

# --- Helper Function for API Calls ---
function Invoke-GeminiApi {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true)]
        [string]$JsonRequestBody,

        [Parameter(Mandatory=$true)]
        [ValidateRange(1,5)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory=$true)]
        [int]$RetryDelaySeconds = 5
    )

    $headers = @{
        'Content-Type' = 'application/json'
    }

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            Write-Verbose "Attempting API call ($attempt/$MaxRetries) to $Url with model $AiModel"
            $response = Invoke-RestMethod -Uri $Url -Method Post -Headers $headers -Body $JsonRequestBody -ErrorAction Stop
            # If successful, return the response and exit the loop
            return $response
        } catch [System.Net.WebException] {
            $statusCode = 0
            if ($_.Exception.Response -ne $null) {
                $statusCode = $_.Exception.Response.StatusCode
            }
            $errorMessage = $_.Exception.Message
            Write-Warning "API call failed (Attempt $attempt/$MaxRetries). Status Code: $statusCode. Message: $errorMessage"

            # Specific check for rate limiting (429) or server errors (5xx)
            if ($statusCode -eq [System.Net.HttpStatusCode]::TooManyRequests -or ($statusCode -ge 500 -and $statusCode -le 599)) {
                 if ($attempt -lt $MaxRetries) {
                    Write-Warning "Retrying in $RetryDelaySeconds seconds..."
                    Start-Sleep -Seconds $RetryDelaySeconds
                } else {
                    Write-Error "Max retries reached. API call failed permanently for this request."
                    throw $_.Exception # Or return $null
                }
            } else {
                # For other client errors (4xx) or network issues, don't retry unless specifically desired
                Write-Error "API call failed with client error or network issue. Not retrying."
                 throw $_.Exception # Or return $null
            }
        } catch {
             Write-Error "An unexpected error occurred during the API call (Attempt $attempt/$MaxRetries): $($_.Exception.Message)"
             if ($attempt -lt $MaxRetries) {
                 Write-Warning "Retrying in $RetryDelaySeconds seconds..."
                 Start-Sleep -Seconds $RetryDelaySeconds
             } else {
                 Write-Error "Max retries reached. API call failed permanently for this request."
                 throw $_.Exception # Or return $null
             }
        }
    }
    # If loop finishes without returning/throwing, something went wrong.
    Write-Error "API call failed after all retries."
    return $null
}


# --- Main Script Logic ---

# Check if source folder exists
if (-not (Test-Path -Path $FolderPath -PathType Container)) {
    Write-Error "Folder not found: $FolderPath"
    Exit 1
}

# Load existing notes if the output file exists, otherwise initialize an empty array
$allNotes = @()
if (Test-Path -Path $OutputJsonFile -PathType Leaf) {
    try {
        Write-Host "Loading existing notes from $OutputJsonFile..."
        $existingJson = Get-Content -Path $OutputJsonFile -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($existingJson)) {
             # Handle potential single object JSON file
             $parsedJson = ConvertFrom-Json -InputObject $existingJson -ErrorAction Stop
             if ($parsedJson -is [array]) {
                 $allNotes = $parsedJson
             } elseif ($parsedJson -is [psobject]) {
                 $allNotes = @($parsedJson)
             } else {
                 Write-Warning "Existing JSON file '$OutputJsonFile' does not contain a valid JSON array or object. Starting fresh."
                 $allNotes = @()
             }
             Write-Host "Loaded $($allNotes.Count) existing notes."
        } else {
            Write-Host "Output file exists but is empty. Starting fresh."
            $allNotes = @()
        }
    } catch {
        Write-Warning "Could not read or parse existing JSON file '$OutputJsonFile'. Starting with an empty list. Error: $($_.Exception.Message)"
        $allNotes = @()
    }
} else {
     Write-Host "Output file '$OutputJsonFile' not found. Will create a new one."
     $allNotes = @()
}

# Determine the next ID based on existing notes
$nextId = if ($allNotes.Count -gt 0) {
    try {
        # Ensure IDs are numeric before finding max
        ($allNotes.Where({$_.id -match '^\d+$'}) | Measure-Object -Property id -Maximum).Maximum + 1
    } catch { 1 } # Fallback if existing IDs are bad
} else { 1 }
Write-Host "Next note ID will start at: $nextId"

# Initialize the order counter for this run
# Consider basing this on existing max order if needed for consistency across runs
# $currentOrder = if ($allNotes.Count -gt 0) { try { ($allNotes.Where({$_.order -match '^\d+$'}) | Measure-Object -Property order -Maximum).Maximum + 1 } catch { 0 } } else { 0 }
# For simplicity, let's keep order starting from 0 for *newly added* notes in this run
$currentOrder = 0
Write-Host "Order field for new notes in this run will start at: $currentOrder"


# Get all .txt files recursively
Write-Host "Searching for .txt files in '$FolderPath'..."
$txtFiles = Get-ChildItem -Path $FolderPath -Filter *.txt -Recurse -File -ErrorAction SilentlyContinue

if ($null -eq $txtFiles -or $txtFiles.Count -eq 0) {
    Write-Warning "No .txt files found in '$FolderPath' or its subfolders."
    Exit 0
}

Write-Host "Found $($txtFiles.Count) .txt files. Processing..."
$processedCount = 0
$addedCount = 0

foreach ($file in $txtFiles) {
    $processedCount++
    $fileName = $file.Name
    $fileBaseName = $file.BaseName # Filename without extension
    Write-Host "Processing file $processedCount/$($txtFiles.Count): $($file.FullName)"

    try {
        # Read file content
        $fileContent = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        $fileDate = $file.LastWriteTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") # ISO 8601 UTC format

        if ([string]::IsNullOrWhiteSpace($fileContent)) {
            Write-Warning "Skipping empty file: $fileName"
            continue
        }

        # --- Step 1: Ask Gemini if it's a note (considering filename) ---
        $classificationPrompt = @"
Analyze the following text content AND its filename. Based on both, determine if this file represents a note (e.g., reminder, meeting minutes, to-do list, idea, code snippet, personal thought, etc.). Don't be too picky but ignore obvious texts that are not notes.
Answer ONLY with the word 'Yes' or 'No'. Do not add any explanation.

Filename: $fileName

Text to analyze:
---
$fileContent
---
Answer:
"@
        $requestBody1 = @{
            contents = @(
                @{
                    parts = @(
                        @{
                            text = $classificationPrompt
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 5

        Write-Verbose "Sending classification request for $fileName..."
        $response1 = Invoke-GeminiApi -Url $geminiApiUrl -JsonRequestBody $requestBody1 -MaxRetries $maxRetries -RetryDelaySeconds $retryDelaySeconds

        # Safely extract classification text for PS 5.1 compatibility
        $classificationResult = $null # Default value
        if ($response1 -ne $null -and $response1.candidates -ne $null -and $response1.candidates.Count -gt 0) {
            $candidate = $response1.candidates[0]
            if ($candidate.content -ne $null -and $candidate.content.parts -ne $null -and $candidate.content.parts.Count -gt 0) {
                $part = $candidate.content.parts[0]
                if ($part.text -ne $null) {
                    $classificationResult = $part.text.Trim()
                }
            }
        }

        if ($null -eq $response1 -and $classificationResult -eq $null) { # Check if API failed AND result is still null
             Write-Warning "Skipping file $fileName due to API error during classification."
             continue
        }

        Write-Verbose "Gemini classification response for ${fileName}: '$classificationResult'"

        # --- Step 2: If it's a note, ask Gemini to generate JSON (considering filename for title) ---
        if ($classificationResult -like 'Yes*') { # Use -like 'Yes*' for flexibility (handles "Yes." or "Yes ")
            Write-Host "File '$fileName' identified as a note."
			
			if ($ApiDelaySeconds -gt 0) {
                Write-Verbose "Waiting $ApiDelaySeconds second(s) before JSON generation call for $fileName..."
                Start-Sleep -Seconds $ApiDelaySeconds
            }

            $jsonGenerationPrompt = @"
Analyze the following note text and its original filename. Generate a structured JSON object representing this note.
Structure the JSON based *only* on the information present in the text.
Infer fields like 'title', 'text', 'status' (only Open or Closed), 'priority' (only Low, Medium, High), isPrivate (true or false), dueDate, *if clearly implied or stated* in the text.

*   **Title:** If the text explicitly contains a title, use that. Otherwise, if the filename (excluding extension) '$fileBaseName' seems like a suitable title, use it. If neither is clear, create a concise title from the first few words of the text.
*   **Text:** This field should contain the main body of the note.
*   **createdAt:** Use the provided date: $fileDate
*   **Other Fields:** Include fields like 'status', 'priority', 'isPrivate' only if strongly indicated by the note's content.

Output ONLY a single, valid JSON object starting with { and ending with }. Do not include ```json markers or any other text.

Filename hint: '$fileBaseName'
Provided createdAt: '$fileDate'

Note text to analyze:
---
$fileContent
---

JSON Output:
"@
            $requestBody2 = @{
                contents = @(
                    @{
                        parts = @(
                            @{
                                text = $jsonGenerationPrompt
                            }
                        )
                    }
                )
                 generationConfig = @{
                    # Ensure Gemini tries to output JSON
                    responseMimeType = "application/json"
                }
            } | ConvertTo-Json -Depth 5 #-Compress # Compress if needed/supported

            Write-Verbose "Sending JSON generation request for $fileName..."
            $response2 = Invoke-GeminiApi -Url $geminiApiUrl -JsonRequestBody $requestBody2 -MaxRetries $maxRetries -RetryDelaySeconds $retryDelaySeconds

            # Safely extract generated JSON text for PS 5.1 compatibility
            $generatedJsonString = $null # Default value
            if ($response2 -ne $null -and $response2.candidates -ne $null -and $response2.candidates.Count -gt 0) {
                $candidate = $response2.candidates[0]
                if ($candidate.content -ne $null -and $candidate.content.parts -ne $null -and $candidate.content.parts.Count -gt 0) {
                    $part = $candidate.content.parts[0]
                    if ($part.text -ne $null) {
                        $generatedJsonString = $part.text.Trim()
                    }
                }
            }

             if ($null -eq $response2 -and $generatedJsonString -eq $null) { # Check if API failed AND result is still null
                Write-Warning "Skipping file $fileName due to API error during JSON generation."
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($generatedJsonString)) {
                Write-Verbose "Raw JSON response from Gemini for ${fileName}: $generatedJsonString"
                # Clean potential markdown code fences sometimes added by models
                $generatedJsonString = $generatedJsonString -replace '^\s*```json\s*', '' -replace '\s*```\s*$', ''

                # Validate and parse the JSON
                try {
                    $jsonObject = ConvertFrom-Json -InputObject $generatedJsonString -ErrorAction Stop

                    # --- Add/Overwrite/Ensure Core & Default Fields ---

                    # Core Fields (ID, CreatedAt, Text)
                    $jsonObject | Add-Member -MemberType NoteProperty -Name 'id' -Value $nextId -Force
                    $jsonObject | Add-Member -MemberType NoteProperty -Name 'createdAt' -Value $fileDate -Force
                    if (-not $jsonObject.PSObject.Properties.Name.Contains('text')) {
                         $jsonObject | Add-Member -MemberType NoteProperty -Name 'text' -Value $fileContent
                         Write-Verbose "Added missing 'text' field to JSON for $fileName"
                    }

                    # Ensure a Title exists (using filename as better fallback)
                    if (-not $jsonObject.PSObject.Properties.Name.Contains('title') -or [string]::IsNullOrWhiteSpace($jsonObject.title)) {
                         # Use cleaned BaseName as the primary fallback title
                         $fallbackTitle = $fileBaseName -replace '[-_]', ' ' # Replace hyphens/underscores with spaces
                         if ([string]::IsNullOrWhiteSpace($fallbackTitle)) {
                             # If BaseName was empty or only separators, use first few words of content
                             $fallbackTitle = ($fileContent -split '\s+' | Select-Object -First 5) -join ' '
                             if ([string]::IsNullOrWhiteSpace($fallbackTitle)) {
                                 # Ultimate fallback if content is also empty/weird
                                 $fallbackTitle = "Note $nextId"
                             }
                         }
                         $jsonObject | Add-Member -MemberType NoteProperty -Name 'title' -Value $fallbackTitle -Force
                         Write-Verbose "Added fallback 'title' ('$fallbackTitle') for $fileName"
                    }


                    # Default Fields (Status, Priority, IsPrivate)
                    if (-not $jsonObject.PSObject.Properties.Name.Contains('status')) {
                        $jsonObject | Add-Member -MemberType NoteProperty -Name 'status' -Value 'Open' -Force
                        Write-Verbose "Added default 'status' field for $fileName"
                    }
                    if (-not $jsonObject.PSObject.Properties.Name.Contains('priority')) {
                        $jsonObject | Add-Member -MemberType NoteProperty -Name 'priority' -Value 'Medium' -Force
                        Write-Verbose "Added default 'priority' field for $fileName"
                    }
                    if (-not $jsonObject.PSObject.Properties.Name.Contains('isPrivate')) {
                        # Note: For boolean, directly use $false or $true
                        $jsonObject | Add-Member -MemberType NoteProperty -Name 'isPrivate' -Value $false -Force
                        Write-Verbose "Added default 'isPrivate' field for $fileName"
                    }

                    # Order Field
                    $jsonObject | Add-Member -MemberType NoteProperty -Name 'order' -Value $currentOrder -Force
                    Write-Verbose "Added 'order' field ($currentOrder) for $fileName"

                    # --- End Field Additions ---


                    # Add the completed object to our list
                    $allNotes += $jsonObject
                    Write-Host "Successfully generated and added JSON for note '$fileName'. New ID: $nextId, Order: $currentOrder"
                    $addedCount++
                    $nextId++ # Increment ID for the next note
                    $currentOrder++ # Increment order for the next note added
					
					if ($ApiDelaySeconds -gt 0) {
						Write-Verbose "Waiting $ApiDelaySeconds second(s) before JSON generation call for $fileName..."
						Start-Sleep -Seconds $ApiDelaySeconds
					}

                } catch {
                    Write-Warning "Failed to parse JSON generated by Gemini for file '$fileName'. Response was: '$generatedJsonString'. Error: $($_.Exception.Message)"
                    # Optionally save the failed response for debugging
                    # $generatedJsonString | Out-File -FilePath ".\failed_json_$($file.BaseName).txt" -Encoding UTF8
                }
            } else {
                Write-Warning "Gemini did not return content for JSON generation for file '$fileName'."
            }

        } else {
            Write-Host "File '$fileName' is not classified as a note. Skipping JSON generation."
        }

    } catch {
        Write-Warning "An error occurred while processing file '$($file.FullName)': $($_.Exception.Message)"
        # Consider whether to continue or stop on error
        # continue
    }

    # Optional: Add a small delay to avoid hitting rate limits if processing many files
    # Start-Sleep -Milliseconds 500
}

# Save the final combined list to the output JSON file
if ($allNotes.Count -gt 0) {
    Write-Host "Saving $($allNotes.Count) notes (including loaded ones if any) to '$OutputJsonFile'..."
    try {
        # Ensure notes are sorted by ID before saving, maintaining some consistency
        $sortedNotes = $allNotes | Sort-Object -Property id
        $finalJson = $sortedNotes | ConvertTo-Json -Depth 10 # Use sufficient depth
        $finalJson | Out-File -FilePath $OutputJsonFile -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "Successfully saved notes."
    } catch {
        Write-Error "Failed to save the final JSON file to '$OutputJsonFile': $($_.Exception.Message)"
    }
} else {
    Write-Host "No new notes were added or loaded. Output file '$OutputJsonFile' may be empty or unchanged."
    # Optionally create an empty array file if it didn't exist and no notes were loaded/added
    if (-not (Test-Path -Path $OutputJsonFile -PathType Leaf)) {
        Write-Host "Creating an empty JSON array file at '$OutputJsonFile'."
        "[]" | Out-File -FilePath $OutputJsonFile -Encoding UTF8
    }
}

Write-Host "Script finished. Processed $processedCount files, added $addedCount new notes."