import { Controller, Post } from '@nestjs/common';
import { AdminService } from './admin.service';

@Controller('admin')
export class AdminController {
  constructor(private readonly adminService: AdminService) {}

  /** Tüm test/demo verisini sıfırlar. Geri dönüş yok, dikkat. */
  @Post('wipe')
  wipe() {
    return this.adminService.wipeAll();
  }
}
