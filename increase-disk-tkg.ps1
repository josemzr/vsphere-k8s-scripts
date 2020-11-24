# taking the inputs
$Server = Read-Host -Prompt 'Input the vCenter name'
$Cluster = Read-Host -Prompt 'Input the vSphere Cluster name'
$TKGCluster = Read-Host -Prompt 'Input the TKG Cluster Name' 
$vcUser = Read-Host -Prompt 'Input the vCenter Username'
$vcPassword = Read-Host -assecurestring "Input the vCenter Password"
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($vcPassword))
$esxPassword = Read-Host -assecurestring "Input the ESXi Root Password"
$esxPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($esxPassword))
$vdisksize = Read-Host -Prompt 'Input the target disk size in GB (>16)'
# set power-cli ssl setting
# Set-PowerCLIConfiguration -InvalidCertificateAction Ignore --confirm:$false
Write-Host "-----------------------------------------------------"
Write-Host "Connecting to vCenter Server to retrieve ESXi host"
# connect to vCenter to retrieve the esxi list
if (connect-viserver -server $Server -user $vcUser -Password $vcPassword)
{
	Write-Host "Successfully logged into vCenter $Server"
	if ($wcpCluster = get-cluster $Cluster)
	{
	Write-Host "$Cluster Found"
		if ($esxiHosts = $wcpCluster | get-vmhost)
		{
	  		foreach ($esxiHost in $esxiHosts)
			{
				disconnect-viserver * -Confirm:$false -Force
				Write-Host "$esxiHost.Name is found"
		 		if (connect-viserver -server $esxiHost.Name -user root -Password $esxPassword)
				{
				Write-Host "Successfully logged into Host $esxiHost.Name"
				Write-Host "Changing all node disk to $vdisksize GB" 
				get-vm $TKGCluster-* | Get-HardDisk |Set-HardDisk -CapacityGB $vdisksize -Confirm:$false
				Write-Host "Restarting all node disk to $vdisksize GB"
				get-vm $TKGCluster-* | Restart-VMGuest -Confirm
				}
			Write-Host "Operation completed! Please check in guest OS"
			}
		}
	}
}
else
{
	Write-Host "Fail to login vCenter"
}