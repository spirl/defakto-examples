import asyncio
from spiffe_defakto import AttestingWorkloadAPIClient, AttestingClientOptions, TcpOptions, AzureMSIAttestor, AzureMSIAttestorOptions
import os

async def main():
    options = AttestingClientOptions(
        trust_domain_id=os.environ["DEFAKTO_TRUST_DOMAIN_ID"],
        attestors=[                                                                                                                                                                                                                                                              
          AzureMSIAttestor(AzureMSIAttestorOptions(                                                                                                                                                                                                                            
              audience="api://AzureADTokenExchange"                                                                                                                                                                                         
          ))                                                                                                                                                                                                                                                                   
        ],
        transport=TcpOptions(
            address=os.environ["DEFAKTO_SERVER_ADDRESS"],
            port=443,
        )
    )
    async with AttestingWorkloadAPIClient(options) as client:
        svid = await client.x509.get_svid()
        print("SPIFFE ID:", svid.id)

asyncio.run(main())  